// FIX-41: blokada zapisu encji zdejmowana tylko przez właściciela (compare-and-delete).
// Uruchomienie: tool/pg_test.sh test/orm_lock_pg_test.dart (potrzebny tylko Redis).
import 'dart:io';

import 'package:ignis/ignis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  if (Platform.environment['IGNIS_DB_HOST'] == null) {
    print('  pominięte — brak IGNIS_DB_HOST (tool/pg_test.sh)');
    return;
  }
  const k = 'lock:test:fix41';
  await Redis.del(k);
  final a = await Orm.lock(k);
  check('blokada założona z losową wartością', a != null && await Redis.get(k) == a);
  // TTL minął, blokadę wziął ktoś inny — spóźniony właściciel nie może jej zdjąć
  await Redis.del(k);
  final b = await Orm.lock(k);
  await Orm.unlock(k, a!);
  check('cudza blokada zostaje po spóźnionym odblokuj', await Redis.get(k) == b);
  await Orm.unlock(k, b!);
  check('właściciel zdejmuje swoją', await Redis.get(k) == null);
  print('\nALL PASSED');
  exit(0);
}
