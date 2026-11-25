// SEC-040.12: Orm.save/upsert(only:) writes just the listed columns. Race: two writers (requests on different
// nodes) read the same row, change DIFFERENT columns and save concurrently — a full-row UPDATE lets the later one
// restore the other's column from its stale copy (lost update). Also: a cached entity's mirror is still invalidated.
// Run: tool/pg_test.sh test/orm_only_pg_test.dart
import 'dart:io';

import 'package:ignis/engine/annotations.dart';
import 'package:ignis/engine/db.dart';
import 'package:ignis/engine/orm.dart';
import 'package:ignis/engine/redis.dart';
import 'package:ignis/engine/schema.dart';
// ignore: unused_import
import 'package:ignis/entities.dart';
import 'pg_guard.dart';
import 'registry_helper.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

@Entity('test_only', pk: 'code')
@Cached()
class OnlyRow {
  String code = '';
  String name = '';
  bool active = true;
  int hits = 0;
}

Future<void> main() async {
  if (skipDestructive()) return;
  EntityRegistry.build(testRegistry(entities: [
    testEntity(const Entity('test_only', pk: 'code'), OnlyRow, OnlyRow.new, [
      FieldMeta('code', String, (o) => (o as OnlyRow).code, (o, v) => (o as OnlyRow).code = v as String,
          defaultValue: ''),
      FieldMeta('name', String, (o) => (o as OnlyRow).name, (o, v) => (o as OnlyRow).name = v as String,
          defaultValue: ''),
      FieldMeta('active', bool, (o) => (o as OnlyRow).active, (o, v) => (o as OnlyRow).active = v as bool,
          defaultValue: true),
      FieldMeta('hits', int, (o) => (o as OnlyRow).hits, (o, v) => (o as OnlyRow).hits = v as int, defaultValue: 0),
    ], cached: true)
  ]));
  await Schema.sync();
  Future<OnlyRow?> read(String code) => Db.inContext(0, () => Orm.read<OnlyRow>(code));
  await Db.asSystem(() async => (await Db.connect()).execute('DELETE FROM test_only'));
  for (final k in ['a', 'b', 'u']) {
    await Redis.del('entity:OnlyRow:$k');
  }

  // 20 rows; for each, two writers on separate pool connections read the row, then save different columns at once
  const n = 20;
  for (var i = 0; i < n; i++) {
    await Db.inContext(0, () => Orm.insert(OnlyRow()..code = 'r$i'..name = 'old'));
  }
  await Future.wait([
    for (var i = 0; i < n; i++)
      () async {
        final x = (await read('r$i'))!, y = (await read('r$i'))!;
        await Future.wait([
          Db.inContext(0, () => Orm.save(x..name = 'new', only: const ['name'])),
          Db.inContext(0, () => Orm.save(y..active = false, only: const ['active'])),
        ]);
      }(),
  ]);
  var both = 0;
  for (var i = 0; i < n; i++) {
    final r = (await read('r$i'))!;
    if (r.name == 'new' && !r.active) both++;
  }
  check('concurrent saves of different columns keep both ($both/$n)', both == n);

  // a counter another writer bumps atomically survives a save of a stale copy with only:
  final stale = (await read('r0'))!;
  await Db.asSystem(() async => (await Db.connect()).execute("UPDATE test_only SET hits = hits + 5 WHERE code='r0'"));
  await Redis.del('entity:OnlyRow:r0');
  await Db.inContext(0, () => Orm.save(stale..name = 'renamed', only: const ['name']));
  final r0 = (await read('r0'))!;
  check('stale copy saved with only: keeps the counter', r0.hits == 5 && r0.name == 'renamed');

  // upsert(only:): a new row is inserted whole, an existing one gets just the listed columns
  await Db.inContext(0, () => Orm.upsert(OnlyRow()..code = 'u'..name = 'n1'..hits = 7, only: const ['name']));
  check('upsert(only:) inserts a new row whole', (await read('u'))?.hits == 7);
  await Db.inContext(0, () => Orm.upsert(OnlyRow()..code = 'u'..name = 'n2'..hits = 0..active = false, only: const ['name']));
  final u = (await read('u'))!;
  check('upsert(only:) on conflict updates just the listed columns', u.name == 'n2' && u.hits == 7 && u.active);

  var threw = false;
  try {
    await Db.inContext(0, () => Orm.save(OnlyRow()..code = 'u', only: const ['nope']));
  } on ArgumentError {
    threw = true;
  }
  check('unknown column in only: throws', threw);

  await Db.asSystem(() async => (await Db.connect()).execute('DELETE FROM test_only'));
  print('\nALL PASSED');
  exit(0);
}
