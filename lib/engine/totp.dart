// ============================================================================
//  totp.dart — second sign-in factor (RFC 6238, compatible with Google Authenticator)
// ----------------------------------------------------------------------------
//  The threat model of this system puts back-office account takeover in second
//  place, right after data leaking between services — and a platform account sees
//  ALL customers. A password alone is too weak a barrier for such an account.
//
//  No external library: TOTP is HMAC-SHA1 of a 30-second counter,
//  and base32 is thirty lines. Adding a dependency for something with a
//  stable specification since 2011 would be a cost without a gain.
// ============================================================================

import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class Totp {
  static const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  static final _rnd = Random.secure();

  /// Tolerance window in 30 s steps — one step back and forward. Phone clocks
  /// can drift by a dozen seconds or so, and the user types the code
  /// by hand anyway.
  static const stepWindow = 1;
  static const stepSeconds = 30;

  /// New secret (160 bits, as in the RFC) in base32 — this is what goes into the app.
  static String newSecret() =>
      encode(Uint8List.fromList(List.generate(20, (_) => _rnd.nextInt(256))));

  static String encode(List<int> bytes) {
    final buf = StringBuffer();
    var bits = 0, value = 0;
    for (final b in bytes) {
      value = (value << 8) | b;
      bits += 8;
      while (bits >= 5) {
        buf.write(_alphabet[(value >> (bits - 5)) & 31]);
        bits -= 5;
      }
    }
    if (bits > 0) buf.write(_alphabet[(value << (5 - bits)) & 31]);
    return buf.toString();
  }

  /// Decodes base32. Spaces and lower-case letters are let through, because people type
  /// the secret by hand; `=` is padding that carries nothing.
  static Uint8List? decode(String s) {
    final t = s.toUpperCase().replaceAll(RegExp(r'[\s=-]'), '');
    if (t.isEmpty) return null;
    final out = <int>[];
    var bits = 0, value = 0;
    for (final z in t.split('')) {
      final i = _alphabet.indexOf(z);
      if (i < 0) return null;
      value = (value << 5) | i;
      bits += 5;
      if (bits >= 8) {
        out.add((value >> (bits - 8)) & 0xff);
        bits -= 8;
      }
    }
    return Uint8List.fromList(out);
  }

  /// Code for a given counter (RFC 4226: dynamic truncation).
  static String codeForCounter(Uint8List secret, int counter) {
    final msg = Uint8List(8);
    var c = counter;
    for (var i = 7; i >= 0; i--) {
      msg[i] = c & 0xff;
      c >>= 8;
    }
    final mac = Hmac(sha1, secret).convert(msg).bytes;
    final offset = mac[mac.length - 1] & 0x0f;
    final slice = ((mac[offset] & 0x7f) << 24) |
        ((mac[offset + 1] & 0xff) << 16) |
        ((mac[offset + 2] & 0xff) << 8) |
        (mac[offset + 3] & 0xff);
    return (slice % 1000000).toString().padLeft(6, '0');
  }

  /// Current code for a base32 secret (null when the secret is unreadable).
  static String? code(String secretBase32, {DateTime? now}) {
    final s = decode(secretBase32);
    if (s == null) return null;
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    return codeForCounter(s, t ~/ stepSeconds);
  }

  /// Whether the code matches — with tolerance for a drifting phone clock.
  /// Constant-time comparison: the code is short, and the server's response is measurable.
  static bool matches(String secretBase32, String given, {DateTime? now}) =>
      codeCounter(secretBase32, given, now: now) != null;

  /// The step counter for which the [given] code matches, or null. The caller remembers
  /// the last accepted counter and rejects `<=` — an observed code will not work a second time.
  static int? codeCounter(String secretBase32, String given, {DateTime? now}) {
    final s = decode(secretBase32);
    final p = given.replaceAll(RegExp(r'\s'), '');
    if (s == null || p.length != 6 || int.tryParse(p) == null) return null;
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    final counter = t ~/ stepSeconds;
    int? hit;
    for (var d = -stepWindow; d <= stepWindow; d++) {
      if (_equal(codeForCounter(s, counter + d), p)) hit ??= counter + d;
    }
    return hit;
  }

  static bool _equal(String a, String b) {
    if (a.length != b.length) return false;
    var r = 0;
    for (var i = 0; i < a.length; i++) {
      r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return r == 0;
  }

  /// The `otpauth://` URL that authenticator apps understand directly.
  /// A QR code is deliberately left out: typing the secret by hand works everywhere,
  /// and a QR generator is a dependency for the convenience of one screen.
  static String address(String secret, String login, String issuer) =>
      'otpauth://totp/${Uri.encodeComponent(issuer)}:${Uri.encodeComponent(login)}'
      '?secret=$secret&issuer=${Uri.encodeComponent(issuer)}&digits=6&period=$stepSeconds';

  /// The secret in groups of four characters — that is how it is typed without mistakes.
  static String readable(String secret) {
    final buf = <String>[];
    for (var i = 0; i < secret.length; i += 4) {
      buf.add(secret.substring(i, min(i + 4, secret.length)));
    }
    return buf.join(' ');
  }
}
