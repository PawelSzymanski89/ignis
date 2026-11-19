// HARD-L.4: nodes starting at the same time on a fresh database — Schema.sync + Seed.seed run under one
// advisory lock, so parallel starts do not race on CREATE TABLE / ADD COLUMN or on the admin account.
// Run: tool/pg_test.sh test/schema_parallel_start_pg_test.dart
import 'dart:io';

import 'package:ignis/engine/db.dart';
import 'package:ignis/engine/orm.dart';
import 'package:ignis/engine/schema.dart';
import 'package:ignis/engine/seed.dart';
// ignore: unused_import
import 'package:ignis/entities.dart';
import 'pg_guard.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  if (skipDestructive()) return;
  EntityRegistry.build();
  for (final run in [1, 2]) {
    final c = await Db.pool();
    await c.execute('DROP SCHEMA public CASCADE');
    await c.execute('CREATE SCHEMA public');
    final errors = <Object>[];
    await Future.wait([
      for (var i = 0; i < 4; i++)
        () async {
          try {
            await Schema.sync();
            await Seed.seed();
          } catch (e) {
            errors.add(e);
          }
        }(),
    ]);
    check('run $run: 4 parallel sync+seed on a fresh database, ${errors.length} errors ${errors.take(2)}',
        errors.isEmpty);
    final accounts = await Db.asSystem(() async => (await (await Db.connect()).execute('SELECT count(*) FROM users')).first[0]);
    check('run $run: exactly one seeded account', accounts == 1);
    final locks = await c.execute("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory'");
    check('run $run: no advisory lock left behind', locks.first[0] == 0);
  }
  await Db.close();
  print('\nALL PASSED');
  exit(0);
}
