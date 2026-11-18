// ============================================================================
//  crypto.dart — secrets in the settings table are stored encrypted (AES-GCM)
// ----------------------------------------------------------------------------
//  Passwords and API keys are typed in by the customer in the panel, so they must
//  be in the database. The encryption key is NOT in the database — the IGNIS_KEY variable (64 hex),
//  the same on all nodes. Without it the node does not start (Ignis.start), and v2 throws
//  instead of storing plaintext; v1 without context (app code, tests) passes plaintext through. Format: `enc:v1:<iv hex>:<ciphertext hex>`.
//  Rotation (no key id in the format): the new key goes to IGNIS_KEY, the old one to IGNIS_KEY_PREVIOUS —
//  decryption tries the current key, then the previous one; bin/rekey.dart re-encrypts what is stored.
// ============================================================================

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Hmac, sha256;
import 'package:pointycastle/export.dart';

import 'config.dart';

class Crypto {
  static const _prefix = 'enc:v1:';

  /// v2: ciphertext bound to its place (AAD = [context], e.g. `"3|smtp.password"`, `"totp|admin"`)
  /// and to an AES key derived from `IGNIS_KEY` (HMAC is a separate use — Signature).
  /// A ciphertext pasted into another field or another service will not decrypt (SEC-A-8).
  static const _prefixV2 = 'enc:v2:';

  /// Whether a value looks like a ciphertext — we do not accept such values from users in plain fields.
  static bool looksEncrypted(String w) => w.startsWith('enc:');

  // keys computed once per process — the environment does not change, and parsing and HMAC ran for every field (PERF-A-2)
  static final Uint8List? _aesKey = _aes(_key);
  static final Uint8List? _aesKeyPrevious = _aes(_keyPrevious);
  static Uint8List? _aes(Uint8List? key) =>
      key == null ? null : Uint8List.fromList(Hmac(sha256, key).convert(utf8.encode('ignis-aes-v2')).bytes);
  static final _rnd = Random.secure();

  static final Uint8List? _key = _parseKey(Platform.environment['IGNIS_KEY'] ?? '');
  static final Uint8List? _keyPrevious = _parseKey(Platform.environment['IGNIS_KEY_PREVIOUS'] ?? '');

  static Uint8List? _parseKey(String hex) {
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hex)) return null;
    // 64 times the same character (zeros from the example, "ffff…") is not a key — the node must not start.
    if (RegExp(r'^(.)\1*$').hasMatch(hex.toLowerCase())) return null;
    return Uint8List.fromList([
      for (var i = 0; i < 64; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
  }

  static bool get available => _key != null;

  /// IGNIS_KEY_PREVIOUS is set but is not a usable key — a typo would silently leave
  /// every not yet re-encrypted secret unreadable, so the node refuses to start.
  static bool get previousKeyInvalid =>
      (Platform.environment['IGNIS_KEY_PREVIOUS'] ?? '').isNotEmpty && _keyPrevious == null;

  /// Random token from Random.secure: [bytesCount] bytes as base64url without `=`
  /// (API keys, tokens in URLs). 32 bytes → 43 characters.
  static String randomToken([int bytesCount = 32]) => base64Url
      .encode(List.generate(bytesCount, (_) => _rnd.nextInt(256)))
      .replaceAll('=', '');

  /// Random id from Random.secure: [charCount] Crockford base32 characters
  /// (`0-9A-Z` without I, L, O, U — readable, unambiguous). 26 characters = 130 bits.
  static String randomBase32([int charCount = 26]) =>
      String.fromCharCodes(List.generate(charCount, (_) => _crockford.codeUnitAt(_rnd.nextInt(32))));

  static const _crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  /// Which settings keys are secrets (password/file fields).
  static bool isSecret(String key) => secretKeys.contains(key);

  /// Settings without secrets — only this may go into the template model.
  /// Code that needs a secret reads it directly from `Permissions.settings`.
  static Map<String, String> withoutSecrets(Map<String, String> u) =>
      {for (final e in u.entries) if (!isSecret(e.key)) e.key: e.value};

  static GCMBlockCipher _cipher(bool forEncryption, Uint8List key, Uint8List iv, [String? aad]) =>
      GCMBlockCipher(AESEngine())
        ..init(forEncryption, AEADParameters(KeyParameter(key), 128, iv,
            aad == null ? Uint8List(0) : Uint8List.fromList(utf8.encode(aad))));

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  static Uint8List _fromHex(String h) => Uint8List.fromList([
        for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16),
      ]);

  /// Encrypts a value if the key is available and the value is not encrypted yet.
  ///
  /// With [context] — v2 and ALWAYS encrypts (also text that looks like a ciphertext: a pasted
  /// `enc:v1:…` is encrypted as text, not accepted as "ready").
  static String encrypt(String plaintext, {String? context}) {
    if (context != null) {
      if (plaintext.isEmpty) return plaintext;
      // without a key we do not store a secret as plaintext (SEC-A-11)
      final k = _aesKey ?? (throw StateError('No IGNIS_KEY — the secret cannot be encrypted'));
      final iv = Uint8List.fromList(List.generate(12, (_) => _rnd.nextInt(256)));
      final out = _cipher(true, k, iv, context).process(Uint8List.fromList(utf8.encode(plaintext)));
      return '$_prefixV2${_hex(iv)}:${_hex(out)}';
    }
    final k = _key;
    if (k == null || plaintext.isEmpty || plaintext.startsWith(_prefix)) return plaintext;
    final iv = Uint8List.fromList(List.generate(12, (_) => _rnd.nextInt(256)));
    final out = _cipher(true, k, iv).process(Uint8List.fromList(utf8.encode(plaintext)));
    return '$_prefix${_hex(iv)}:${_hex(out)}';
  }

  /// Decrypts; plaintext values (from before the key was enabled) come back unchanged.
  /// v2 requires the same [context] as when encrypting; v1 (without AAD) is read for compatibility
  /// with data from before v2 — the next write rewrites it as v2. The current key is tried first,
  /// then IGNIS_KEY_PREVIOUS; unreadable → `''` (better empty than a ciphertext in a password field).
  static String decrypt(String w, {String? context}) {
    if (!w.startsWith(_prefix) && !w.startsWith(_prefixV2)) return w;
    return _open(w, context)?.$1 ?? '';
  }

  /// For bin/rekey.dart: a stored ciphertext that only IGNIS_KEY_PREVIOUS reads, or a v1 one, comes back
  /// as v2 under the current key. `null` — nothing to do (plaintext, or v2 under the current key).
  /// [FormatException] — neither key reads it.
  static String? reencrypt(String w, {required String context}) {
    if (!w.startsWith(_prefix) && !w.startsWith(_prefixV2)) return null;
    final (plaintext, current) = _open(w, context) ??
        (throw const FormatException('Ciphertext unreadable with IGNIS_KEY and IGNIS_KEY_PREVIOUS'));
    return current && w.startsWith(_prefixV2) ? null : encrypt(plaintext, context: context);
  }

  /// (plaintext, read with the current key?) or null when neither key reads [w].
  static (String, bool)? _open(String w, String? context) {
    final v2 = w.startsWith(_prefixV2);
    final parts = w.substring(v2 ? _prefixV2.length : _prefix.length).split(':');
    if (parts.length != 2 || (v2 && context == null)) return null;
    final keys = v2 ? [(_aesKey, true), (_aesKeyPrevious, false)] : [(_key, true), (_keyPrevious, false)];
    for (final (key, current) in keys) {
      if (key == null) continue;
      try {
        final iv = _fromHex(parts[0]);
        return (utf8.decode(_cipher(false, key, iv, v2 ? context : null).process(_fromHex(parts[1]))), current);
      } catch (_) {}
    }
    return null;
  }
}
