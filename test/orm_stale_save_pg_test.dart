// IGNIS-053.4: Orm.save (UPDATE without ifUnchanged) that matches no row — another tenant's row hidden by RLS,
// a deleted row — throws StaleEntity instead of reporting success; Orm.delete returns whether a row went away.
// Run: tool/pg_test.sh test/orm_stale_save_pg_test.dart
import 'dart:io';

import 'package:ignis/engine/annotations.dart';
import 'package:ignis/engine/db.dart';
import 'package:ignis/engine/orm.dart';
import 'package:ignis/engine/schema.dart';
// ignore: unused_import
import 'package:ignis/entities.dart';
import 'pg_guard.dart';
import 'registry_helper.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

class StaleNote {
  int id = 0;
  String tenant = '';
  String body = '';
}

Future<bool> stale(Future<void> Function() f) async {
  try {
    await f();
    return false;
  } on StaleEntity {
    return true;
  }
}

Future<void> main() async {
  if (skipDestructive()) return;
  EntityRegistry.build(testRegistry(entities: [
    testEntity(const Entity('test_stale_notes', tenantColumn: 'tenant'), StaleNote, StaleNote.new, [
      FieldMeta('id', int, (o) => (o as StaleNote).id, (o, v) => (o as StaleNote).id = v as int, defaultValue: 0),
      FieldMeta('tenant', String, (o) => (o as StaleNote).tenant, (o, v) => (o as StaleNote).tenant = v as String,
          defaultValue: ''),
      FieldMeta('body', String, (o) => (o as StaleNote).body, (o, v) => (o as StaleNote).body = v as String,
          defaultValue: ''),
    ]),
  ]));
  await Schema.sync();
  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute('DELETE FROM test_stale_notes');
    await c.execute("INSERT INTO test_stale_notes (id, tenant, body) VALUES (1, 'a', 'mine'), (2, 'b', 'theirs')");
  });
  Future<String?> body(int id) => Db.asSystem(() async =>
      (await (await Db.connect()).execute('SELECT body FROM test_stale_notes WHERE id = $id')).firstOrNull?[0] as String?);

  check('save of another tenant\'s row in context a → StaleEntity', await Db.asTenant('a', () => stale(() => Orm.save(
      StaleNote()
        ..id = 2
        ..tenant = 'b'
        ..body = 'hacked'))));
  check('…and the row is unchanged', await body(2) == 'theirs');
  check('save of own row with the same values → OK (PG counts matched rows, not changed ones)',
      !await Db.asTenant('a', () => stale(() => Orm.save(StaleNote()
        ..id = 1
        ..tenant = 'a'
        ..body = 'mine'))));
  check('save of own row with a new value → OK and written', !await Db.asTenant('a', () => stale(() => Orm.save(
      StaleNote()
        ..id = 1
        ..tenant = 'a'
        ..body = 'edited'))) && await body(1) == 'edited');
  check('save of a missing id → StaleEntity', await Db.asSystem(() => stale(() => Orm.save(StaleNote()
    ..id = 99
    ..tenant = 'a'))));
  check('delete of a missing id → false', await Db.asSystem(() => Orm.delete<StaleNote>(99)) == false);
  check('delete of another tenant\'s row in context a → false, row kept',
      await Db.asTenant('a', () => Orm.delete<StaleNote>(2)) == false && await body(2) == 'theirs');
  check('delete of own row → true', await Db.asTenant('a', () => Orm.delete<StaleNote>(1)) == true && await body(1) == null);

  await Db.asSystem(() async => (await Db.connect()).execute('DROP TABLE test_stale_notes'));
  print('\nALL PASSED');
  exit(0);
}
