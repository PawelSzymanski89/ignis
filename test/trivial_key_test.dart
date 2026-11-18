// FIX-54: IGNIS_KEY z jednego powtórzonego znaku nie jest kluczem (node nie wstanie).
// Szyfr czyta środowisko raz na proces — każdy przypadek w osobnym procesie.
import 'dart:io';

import 'package:ignis/engine/crypto.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main(List<String> a) async {
  if (a.isNotEmpty) {
    stdout.write(Crypto.available ? 'tak' : 'nie');
    return;
  }
  Future<bool> available(String key) async => (await Process.run(
          Platform.resolvedExecutable, [Platform.script.toFilePath(), 'dziecko'],
          environment: {'IGNIS_KEY': key}))
      .stdout == 'tak';
  check('64 zera — odrzucony', !await available('0' * 64));
  check('64 × F — odrzucony (wielkość liter bez znaczenia)', !await available('fF' * 32));
  check('losowy klucz — przyjęty', await available('0123456789abcdef' * 4));
}
