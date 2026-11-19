// HARD-L.5/L.12.2: the @Cached mirror is invalidated on write (right away and after COMMIT/ROLLBACK) and filled
// only by reads outside a writing transaction — no phantom after a rollback or a savepoint, read-your-writes in a
// request, no stale row after an interleaved read/write; DateTime in UTC; an unreadable entry is a miss.
// Run: tool/pg_test.sh test/cached_mirror_pg_test.dart
import 'dart:async';
import 'dart:io';

import 'package:ignis/engine/annotations.dart';
import 'package:ignis/engine/db.dart';
import 'package:ignis/engine/orm.dart';
import 'package:ignis/engine/redis.dart';
import 'package:ignis/engine/schema.dart';
// ignore: unused_import
import 'package:ignis/entities.dart';
import 'pg_guard.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

@Entity('test_mirror', pk: 'code')
@Cached()
class MirrorRow {
  String code = '';
  String name = '';
  DateTime? at;
}

Future<void> main() async {
  if (skipDestructive()) return;
  EntityRegistry.build();
  await Schema.sync();
  await Db.asSystem(() async => (await Db.connect()).execute('DELETE FROM test_mirror'));
  for (final k in ['x1', 'x2', 'x3', 'x4', 'x5', 'x6', 'x7']) {
    await Redis.del('entity:MirrorRow:$k');
  }

  try {
    await Db.inContext(0, () async {
      await Orm.insert(MirrorRow()
        ..code = 'x1'
        ..name = 'phantom');
      throw StateError('request failed');
    });
  } on StateError catch (_) {}
  check('rolled-back insert leaves no mirror', await Redis.get('entity:MirrorRow:x1') == null);
  check('…and Orm.read does not return the phantom', await Db.inContext(0, () => Orm.read<MirrorRow>('x1')) == null);

  Future<String> name(String code) async => (await Db.inContext(0, () => Orm.read<MirrorRow>(code)))?.name ?? '-';
  Future<void> put(String code, String n) => Db.inContext(0, () => Orm.upsert(MirrorRow()
    ..code = code
    ..name = n));

  // the mirror holds v1; a request writes v2 and reads it back
  await put('x2', 'v1');
  check('read fills the mirror', await name('x2') == 'v1' && await Redis.get('entity:MirrorRow:x2') != null);
  final ownWrite = await Db.inContext(0, () async {
    await Orm.save(MirrorRow()
      ..code = 'x2'
      ..name = 'v2');
    final r = (await Orm.read<MirrorRow>('x2'))?.name;
    return (r, await Redis.get('entity:MirrorRow:x2'));
  });
  check('save → read in one request returns the new row and leaves no mirror', ownWrite == ('v2', null));
  check('…and after COMMIT the mirror is refilled with v2', await name('x2') == 'v2' && await name('x2') == 'v2');
  final ownDelete = await Db.inContext(0, () async {
    await Orm.delete<MirrorRow>('x2');
    return Orm.read<MirrorRow>('x2');
  });
  check('delete → read in one request returns null', ownDelete == null);

  // an insert in a rolled-back savepoint inside a committed transaction
  await Db.inContext(0, () async {
    try {
      await (await Db.connect()).runTx((_) async {
        await Orm.insert(MirrorRow()
          ..code = 'x4'
          ..name = 'phantom');
        throw StateError('savepoint rolled back');
      });
    } on StateError catch (_) {}
  });
  check('rolled-back savepoint in a committed transaction leaves no mirror key',
      await Redis.get('entity:MirrorRow:x4') == null && await name('x4') == '-');

  // a reader fills on a miss (v1) and its transaction outlives a writer that commits v2: v1 must not stay
  await put('x5', 'v1');
  await Redis.del('entity:MirrorRow:x5');
  final readerRead = Completer<void>(), writerDone = Completer<void>();
  final reader = Db.inContext(0, () async {
    final r = await Orm.read<MirrorRow>('x5');
    readerRead.complete();
    await writerDone.future;
    return r?.name;
  });
  await readerRead.future;
  await put('x5', 'v2');
  writerDone.complete();
  check('interleaved read(v1)/save(v2) leaves no v1 in the mirror', await reader == 'v1' && await name('x5') == 'v2');

  // a writer still open when a reader fills the mirror from the committed v1: dropped after the writer's COMMIT
  await put('x6', 'v1');
  await Redis.del('entity:MirrorRow:x6');
  final gate = Completer<void>(), wrote = Completer<void>();
  final writer = Db.inContext(0, () async {
    await Orm.upsert(MirrorRow()
      ..code = 'x6'
      ..name = 'v2');
    wrote.complete();
    await gate.future;
  });
  await wrote.future;
  final stale = await name('x6');
  gate.complete();
  await writer;
  check('a fill made before the writer committed is dropped after COMMIT', stale == 'v1' && await name('x6') == 'v2');

  final at = DateTime.utc(2026, 11, 18, 12, 30, 15, 123);
  await Db.inContext(0, () => Orm.upsert(MirrorRow()
    ..code = 'x7'
    ..name = 'dated'
    ..at = at.toLocal()));
  await name('x7');
  final raw = await Redis.get('entity:MirrorRow:x7');
  final fromMirror = await Db.inContext(0, () => Orm.read<MirrorRow>('x7'));
  check('DateTime is stored in UTC and reads back equal', raw != null && raw.contains('12:30:15.123Z') &&
      fromMirror?.at?.isAtSameMomentAs(at) == true);
  await Redis.set('entity:MirrorRow:x7', '{"code":"x7","name":"broken","at":"not a date"}');
  check('an unreadable mirror entry is a miss (database row, entry dropped)',
      await name('x7') == 'dated' && await Redis.get('entity:MirrorRow:x7') == null);

  await put('x3', 'to delete');
  try {
    await Db.inContext(0, () async {
      await Orm.delete<MirrorRow>('x3');
      throw StateError('request failed');
    });
  } on StateError catch (_) {}
  check('rolled-back delete: row still readable', await name('x3') == 'to delete');
  await Db.inContext(0, () => Orm.delete<MirrorRow>('x3'));
  check('committed delete drops the mirror', await Redis.get('entity:MirrorRow:x3') == null);
  check('…and the row', await name('x3') == '-');

  await Db.asSystem(() async => (await Db.connect()).execute('DROP TABLE test_mirror'));
  for (final k in ['x1', 'x2', 'x3', 'x4', 'x5', 'x6', 'x7']) {
    await Redis.del('entity:MirrorRow:$k');
  }
  await Db.close();
  print('\nALL PASSED');
  exit(0);
}
