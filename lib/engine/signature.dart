// ============================================================================
//  signature.dart — signing text with the node key and constant-time comparison
// ============================================================================

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

class Signing {
  /// Signature of any text with the NODE key (`IGNIS_KEY`), without asking the database.
  /// For things that come back to us in a URL and must be ours — a message
  /// after a redirect. The key is shared by the nodes, so a signature from node1
  /// verifies on node2. Without the key the node does not start anyway.
  ///
  /// [target] separates uses (`flash`, `download-link`…): a signature from one does not pass
  /// in another. A 128-bit tag (32 hex chars) — enough for long-lived links too.
  static String textValue(String target, String text) {
    if (target.isEmpty || target.contains(':')) throw ArgumentError.value(target, 'target', 'non-empty, without ":"');
    return Hmac(sha256, _signingKey).convert(utf8.encode('$target:$text')).toString().substring(0, 32);
  }

  /// HMAC key derived from `IGNIS_KEY`, not the AES key itself — the same secret does not work
  /// in two algorithms at once.
  static final List<int> _signingKey =
      Hmac(sha256, utf8.encode(Platform.environment['IGNIS_KEY'] ?? '')).convert(utf8.encode('ignis/podpis/v1')).bytes;

  /// Constant-time comparison — `==` stops at the first difference, and that can
  /// be measured.
  static bool equal(String a, String b) {
    if (a.length != b.length) return false;
    var r = 0;
    for (var i = 0; i < a.length; i++) {
      r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return r == 0;
  }
}
