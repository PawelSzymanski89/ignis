// ============================================================================
//  jwt.dart — RS256 JWT signature with a PEM private key (Google service accounts etc.)
// ----------------------------------------------------------------------------
//  Przyjmuje PEM PKCS#8 („PRIVATE KEY”) i PKCS#1 („RSA PRIVATE KEY”).
//  RSASSA-PKCS1-v1_5 is deterministic — the same key and content give the same signature.
// ============================================================================

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

class Jwt {
  static String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');

  /// RSA key from PEM; [FormatException] when it is not an RSA private key.
  static RSAPrivateKey rsaKey(String pem) {
    final m = RegExp(r'-----BEGIN (RSA )?PRIVATE KEY-----([^-]+)-----END (RSA )?PRIVATE KEY-----')
        .firstMatch(pem);
    if (m == null) throw const FormatException('No PEM PRIVATE KEY');
    try {
      var seq = ASN1Parser(base64.decode(m[2]!.replaceAll(RegExp(r'\s'), '')))
          .nextObject() as ASN1Sequence;
      if (m[1] == null) {
        final inner = seq.elements![2] as ASN1OctetString;
        seq = ASN1Parser(inner.valueBytes!).nextObject() as ASN1Sequence;
      }
      BigInt i(int n) => (seq.elements![n] as ASN1Integer).integer!;
      return RSAPrivateKey(i(1), i(3), i(4), i(5));
    } catch (e) {
      throw FormatException('Invalid RSA key: $e');
    }
  }

  /// JWT `{"alg":"RS256","typ":"JWT"}` with [claims] signed with the [pem] key.
  static String rs256(Map<String, Object?> claims, String pem) {
    final content = '${_b64(utf8.encode(jsonEncode({'alg': 'RS256', 'typ': 'JWT'})))}'
        '.${_b64(utf8.encode(jsonEncode(claims)))}';
    final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(rsaKey(pem)));
    final signature = signer.generateSignature(Uint8List.fromList(utf8.encode(content)));
    return '$content.${_b64(signature.bytes)}';
  }
}
