// Test Szyfr.losowyToken — base64url bez `=`, długość z liczby bajtów, bez bazy.
import 'dart:convert';

import '../lib/engine/crypto.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  final t = Crypto.randomToken();
  check('32 bajty → 43 znaki', t.length == 43);
  check('tylko alfabet base64url, bez =', RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(t));
  check('dekoduje się do 32 bajtów', base64Url.decode('$t=').length == 32);
  check('16 bajtów → 22 znaki', Crypto.randomToken(16).length == 22);
  final hundred = {for (var i = 0; i < 100; i++) Crypto.randomToken()};
  check('100 losowań bez powtórki', hundred.length == 100);
}
