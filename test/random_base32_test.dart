// Test Szyfr.losowyBase32 — alfabet Crockforda, długość, brak powtórek, bez bazy.
import '../lib/engine/crypto.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  final t = Crypto.randomBase32();
  check('domyślnie 26 znaków', t.length == 26);
  check('8 znaków na żądanie', Crypto.randomBase32(8).length == 8);
  final thousand = {for (var i = 0; i < 1000; i++) Crypto.randomBase32()};
  check('1000 losowań bez powtórki', thousand.length == 1000);
  final chars = thousand.join().split('').toSet();
  check('tylko alfabet Crockforda (bez I, L, O, U)', chars.every(RegExp(r'^[0-9A-HJKMNP-TV-Z]$').hasMatch));
  check('wszystkie 32 znaki występują', chars.length == 32);
}
