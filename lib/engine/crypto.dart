// ============================================================================
//  crypto.dart — secrets in the settings table are stored encrypted (AES-GCM)
// ----------------------------------------------------------------------------
//  Passwords and API keys are typed in by the customer in the panel, so they must
//  be in the database. The encryption key is NOT in the database — the IGNIS_KEY variable (64 hex),
//  the same on all nodes. Without it the node does not start (Ignis.start), and v2 throws
//  instead of storing plaintext; v1 without context (app code, tests) passes plaintext through. Format: `enc:v1:<iv hex>:<ciphertext hex>`.
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
  static final Uint8List? _aesKey = _key == null
      ? null
      : Uint8List.fromList(Hmac(sha256, _key!).convert(utf8.encode('ignis-aes-v2')).bytes);
  static final _rnd = Random.secure();

  static final Uint8List? _key = () {
    final hex = Platform.environment['IGNIS_KEY'] ?? '';
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hex)) return null;
    // 64 times the same character (zeros from the example, "ffff…") is not a key — the node must not start.
    // There is no key rotation (key id in the ciphertext) in 0.1.0: changing IGNIS_KEY = losing the secrets.
    if (RegExp(r'^(.)\1*$').hasMatch(hex.toLowerCase())) return null;
    return Uint8List.fromList([
      for (var i = 0; i < 64; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
  }();

  static bool get available => _key != null;

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
  /// with data from before v2 — the next write rewrites it as v2.
  static String decrypt(String w, {String? context}) {
    if (w.startsWith(_prefixV2)) {
      final k = _aesKey;
      final parts = w.substring(_prefixV2.length).split(':');
      if (k == null || context == null || parts.length != 2) return '';
      try {
        return utf8.decode(_cipher(false, k, _fromHex(parts[0]), context).process(_fromHex(parts[1])));
      } catch (_) {
        return '';
      }
    }
    if (!w.startsWith(_prefix)) return w;
    final k = _key;
    if (k == null) return ''; // the key is gone — better empty than a ciphertext in a password field
    final parts = w.substring(_prefix.length).split(':');
    if (parts.length != 2) return '';
    try {
      return utf8.decode(_cipher(false, k, _fromHex(parts[0])).process(_fromHex(parts[1])));
    } catch (_) {
      return '';
    }
  }
}
