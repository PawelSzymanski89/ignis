// IGNIS-053.10: folders.created_at is written in UTC (ISO-8601 with `Z`), like files.uploaded_at — before, it was the
// node's local time without an offset, so nodes in different time zones wrote incomparable values.
// Run: tool/pg_test.sh test/folder_created_utc_pg_test.dart
import 'dart:io';

import 'package:ignis/ignis.dart';
import 'package:postgres/postgres.dart' show Sql;
// ignore: unused_import
import 'package:ignis/entities.dart';
import 'package:ignis/ignis_registry.g.dart';
import 'pg_guard.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  if (skipDestructive()) return;
  EntityRegistry.build(ignisRegistry);
  await Schema.sync();
  Future<void> clean() => Db.asSystem(() async =>
      (await Db.connect()).execute("DELETE FROM folders WHERE service = 0 AND created_by = 'utc053'"));
  await clean();
  final before = DateTime.now().toUtc();
  final id = await Db.inContext(0, () => Storage.createFolder('/', 'utc053', 'utc053', 0));
  final at = await Db.asSystem(() async => (await (await Db.connect())
          .execute(Sql.named('SELECT created_at FROM folders WHERE id=@i'), parameters: {'i': id}))
      .first[0] as String);
  check('created_at ends with Z ($at)', at.endsWith('Z'));
  final t = DateTime.parse(at);
  check('…and is the creation instant', t.isUtc && t.difference(before).inSeconds.abs() < 60);
  await clean();
  print('\nALL PASSED');
  exit(0);
}
