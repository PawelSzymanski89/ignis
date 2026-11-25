// SEC-041.1: Orm.save/upsert(ifUnchanged:) — optimistic lock for "the same form edited twice". Race: two users open
// the same form (same row, same stamp), both submit concurrently on different nodes — without the check the later
// one silently overwrites the earlier (last-writer-wins). With it exactly one is written, the other gets StaleEntity.
// Run: tool/pg_test.sh test/orm_if_unchanged_pg_test.dart
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

@Entity('test_stamp', pk: 'code')
@Cached()
class StampRow {
  String code = '';
  String name = '';
  int hits = 0;
}

const form = ['name'];

Future<bool> stale(Future<void> Function() f) async {
  try {
    await Db.inContext(0, f);
    return false;
  } on StaleEntity {
    return true;
  }
}

Future<void> main() async {
  if (skipDestructive()) return;
  EntityRegistry.build(testRegistry(entities: [
    testEntity(const Entity('test_stamp', pk: 'code'), StampRow, StampRow.new, [
      FieldMeta('code', String, (o) => (o as StampRow).code, (o, v) => (o as StampRow).code = v as String,
          defaultValue: ''),
      FieldMeta('name', String, (o) => (o as StampRow).name, (o, v) => (o as StampRow).name = v as String,
          defaultValue: ''),
      FieldMeta('hits', int, (o) => (o as StampRow).hits, (o, v) => (o as StampRow).hits = v as int, defaultValue: 0),
    ], cached: true)
  ]));
  await Schema.sync();
  Future<StampRow?> read(String code) => Db.inContext(0, () => Orm.read<StampRow>(code));
  await Db.asSystem(() async => (await Db.connect()).execute('DELETE FROM test_stamp'));
  await Redis.cmd(['EVAL', "for _,k in ipairs(redis.call('KEYS','entity:StampRow:*')) do redis.call('DEL',k) end", '0']);

  // 20 rows × 2 concurrent submits of the same form from the same stamp: exactly one written, one refused
  const n = 20;
  for (var i = 0; i < n; i++) {
    await Db.inContext(0, () => Orm.insert(StampRow()..code = 'r$i'..name = 'old'));
  }
  var refused = 0, kept = 0;
  await Future.wait([
    for (var i = 0; i < n; i++)
      () async {
        final x = (await read('r$i'))!, y = (await read('r$i'))!;
        final s = Orm.stamp(x, form);
        final r = await Future.wait([
          stale(() => Orm.save(x..name = 'A', only: form, ifUnchanged: s)),
          stale(() => Orm.save(y..name = 'B', only: form, ifUnchanged: s)),
        ]);
        if (r.where((e) => e).length == 1) refused++;
        final now = (await read('r$i'))!.name;
        if (now == (r[0] ? 'B' : 'A')) kept++;
      }(),
  ]);
  check('same form, same stamp, concurrent: one written, one refused ($refused/$n)', refused == n);
  check('the written one is the one that was not refused ($kept/$n)', kept == n);

  // a column outside the form changed meanwhile (counter) does not refuse the form
  final c = (await read('r0'))!, sc = Orm.stamp(c, form);
  await Db.asSystem(() async => (await Db.connect()).execute("UPDATE test_stamp SET hits = hits + 1 WHERE code='r0'"));
  check('change of a column outside only: is not a conflict',
      !await stale(() => Orm.save(c..name = 'C', only: form, ifUnchanged: sc)));

  // upsert: '' = "no row when the form was opened"
  check("upsert ifUnchanged:'' inserts a new row", !await stale(() => Orm.upsert(StampRow()..code = 'u'..name = 'n1', only: form, ifUnchanged: '')));
  check("upsert ifUnchanged:'' refuses when someone added the row", await stale(() => Orm.upsert(StampRow()..code = 'u'..name = 'n2', only: form, ifUnchanged: '')));
  final su = Orm.stamp(await read('u'), form);
  check('upsert with the current stamp overwrites', !await stale(() => Orm.upsert(StampRow()..code = 'u'..name = 'n3', only: form, ifUnchanged: su)));
  check('upsert with an old stamp is refused', await stale(() => Orm.upsert(StampRow()..code = 'u'..name = 'n4', only: form, ifUnchanged: su)));
  check('the refused writes left the row alone', (await read('u'))!.name == 'n3');

  // concurrent first creation of the same key: one inserts, the other is refused (not silently overwritten)
  final r = await Future.wait([
    stale(() => Orm.upsert(StampRow()..code = 'v'..name = 'X', only: form, ifUnchanged: '')),
    stale(() => Orm.upsert(StampRow()..code = 'v'..name = 'Y', only: form, ifUnchanged: '')),
  ]);
  check('concurrent first upsert of one key: exactly one refused', r.where((e) => e).length == 1);

  // deleted row
  final d = (await read('r1'))!, sd = Orm.stamp(d, form);
  await Db.asSystem(() async => (await Db.connect()).execute("DELETE FROM test_stamp WHERE code='r1'"));
  check('save of a deleted row is refused', await stale(() => Orm.save(d..name = 'Z', only: form, ifUnchanged: sd)));

  await Db.asSystem(() async => (await Db.connect()).execute('DELETE FROM test_stamp'));
  print('\nALL PASSED');
  exit(0);
}
