// HARD-L.5: the @Cached mirror follows COMMIT — a rolled-back insert leaves no phantom in Redis, a write
// lands in the mirror only after the transaction ends, and DateTime fields read back from the mirror.
// Run: tool/pg_test.sh test/cached_mirror_pg_test.dart
import 'dart:io';

import 'package:ignis/engine/annotations.dart';
import 'package:ignis/engine/db.dart';
import 'package:ignis/engine/orm.dart';
import 'package:ignis/engine/redis.dart';
import 'package:ignis/engine/schema.dart';
// ignore: unused_import
import 'package:ignis/entities.dart';

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
  if (Platform.environment['IGNIS_DB_HOST'] == null) {
    print('  skipped — no IGNIS_DB_HOST (tool/pg_test.sh)');
    return;
  }
  EntityRegistry.build();
  await Schema.sync();
  await Db.asSystem(() async => (await Db.connect()).execute('DELETE FROM test_mirror'));
  for (final k in ['x1', 'x2', 'x3']) {
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

  final at = DateTime.utc(2026, 11, 18, 12, 30, 15, 123);
  late String? during;
  await Db.inContext(0, () async {
    await Orm.upsert(MirrorRow()
      ..code = 'x2'
      ..name = 'kept'
      ..at = at);
    during = await Redis.get('entity:MirrorRow:x2');
  });
  check('mirror not written before COMMIT', during == null);
  check('mirror written after COMMIT', await Redis.get('entity:MirrorRow:x2') != null);
  await Db.asSystem(() async => (await Db.connect()).execute("DELETE FROM test_mirror WHERE code = 'x2'"));
  final cached = await Db.inContext(0, () => Orm.read<MirrorRow>('x2'));
  check('DateTime read from the mirror equals the original',
      cached != null && cached.name == 'kept' && cached.at == at);

  await Db.inContext(0, () async {
    await Orm.upsert(MirrorRow()
      ..code = 'x3'
      ..name = 'to delete');
  });
  try {
    await Db.inContext(0, () async {
      await Orm.delete<MirrorRow>('x3');
      throw StateError('request failed');
    });
  } on StateError catch (_) {}
  final kept = await Db.inContext(0, () => Orm.read<MirrorRow>('x3'));
  check('rolled-back delete: row still readable', kept?.name == 'to delete');
  await Db.inContext(0, () => Orm.delete<MirrorRow>('x3'));
  check('committed delete drops the mirror', await Redis.get('entity:MirrorRow:x3') == null);
  check('…and the row', await Db.inContext(0, () => Orm.read<MirrorRow>('x3')) == null);

  await Db.asSystem(() async => (await Db.connect()).execute('DROP TABLE test_mirror'));
  for (final k in ['x1', 'x2', 'x3']) {
    await Redis.del('entity:MirrorRow:$k');
  }
  await Db.close();
  print('\nALL PASSED');
  exit(0);
}
