// Test odczytu body stron @Page(api: true) — rozpakowanie gzip z limitem, bez bazy.
import 'dart:convert';
import 'dart:io';

import '../lib/engine/engine.dart';
import '../lib/engine/upload.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

bool throws<T extends Object>(void Function() f) {
  try {
    f();
    return false;
  } on T {
    return true;
  }
}

void main() {
  const json = '{"zdarzenie":"start","ąę":"żółć"}';

  print('bez gzip:');
  check('tekst bez zmian', readBody(utf8.encode(json), false) == json);
  check('zepsute utf8 nie rzuca', readBody([0xff, 0x41], false).endsWith('A'));

  print('gzip:');
  check('rozpakowany', readBody(gzip.encode(utf8.encode(json)), true) == json);
  final bomb = gzip.encode(List.filled(9 * 1024 * 1024, 0x20));
  check('bomba (9 MB → ${bomb.length} B) ponad limit 8 MB',
      throws<UploadTooLarge>(() => readBody(bomb, true)));
  final exactly = gzip.encode(List.filled(8 * 1024 * 1024, 0x20));
  check('dokładnie 8 MB przechodzi', readBody(exactly, true).length == 8 * 1024 * 1024);
  check('mały limit też liczony',
      throws<UploadTooLarge>(() => readBody(gzip.encode(utf8.encode(json)), true, limit: 10)));
  check('zepsuty gzip → FormatException',
      throws<FormatException>(() => readBody([1, 2, 3, 4, 5], true)));
  check('tekst zamiast gzip → FormatException',
      throws<FormatException>(() => readBody(utf8.encode(json), true)));

  print('binarne:');
  final bin = [0, 255, 0x7f, 0x45, 0x4c, 0x46];
  check('bajty bez zmian (bez dekodowania utf8)', readBytes(bin, false).join(',') == bin.join(','));
  check('bajty po gzip', readBytes(gzip.encode(bin), true).join(',') == bin.join(','));
  check('bajty: limit rozpakowania', throws<UploadTooLarge>(() => readBytes(gzip.encode(List.filled(100, 1)), true, limit: 99)));

  print('wszystko ok');
}
