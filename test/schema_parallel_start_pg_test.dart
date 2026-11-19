// HARD-L.4: nodes starting at the same time on a fresh database — Schema.sync + Seed.seed run under one
// advisory lock, so parallel starts do not race on CREATE TABLE / ADD COLUMN or on the admin account.
// Run: tool/pg_test.sh test/schema_parallel_start_pg_test.dart
import 'dart:io';

import 'package:ignis/engine/db.dart';
import 'package:ignis/engine/orm.dart';
import 'package:ignis/engine/schema.dart';
import 'package:ignis/engine/seed.dart';
import 'package:postgres/postgres.dart';
// ignore: unused_import
import 'package:ignis/entities.dart';
import 'pg_guard.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  if (skipDestructive()) return;
  final env = Platform.environment;
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
            // as in Ignis.start: one lock around both
            await Schema.underStartLock(() async {
              await Schema.sync();
              await Seed.seed();
            });
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

  // a session that holds the start-up lock (a stuck migration): the start gives up with a clear error
  final holder = await Connection.open(
      Endpoint(
          host: env['IGNIS_DB_HOST']!,
          port: int.parse(env['IGNIS_DB_PORT'] ?? '5432'),
          database: env['IGNIS_DB_NAME']!,
          username: env['IGNIS_DB_USER'],
          password: env['IGNIS_DB_PASS']),
      settings: const ConnectionSettings(sslMode: SslMode.disable));
  await holder.execute('SELECT pg_advisory_lock(${Schema.startLock})');
  Schema.startLockWait = const Duration(seconds: 2);
  Object? timeout;
  final watch = Stopwatch()..start();
  try {
    await Schema.sync(); // logs "waiting for start-up lock"
  } catch (e) {
    timeout = e;
  }
  check('lock held elsewhere → StateError after the limit (${watch.elapsed.inSeconds} s): $timeout',
      timeout is StateError && '$timeout'.contains('start-up lock') && watch.elapsed.inSeconds < 10);
  await holder.close();

  Object? bodyError;
  try {
    await Schema.underStartLock(() async => throw const FormatException('body failed'));
  } catch (e) {
    bodyError = e;
  }
  final left = await (await Db.pool()).execute("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory'");
  check('an error in the locked body is reported as is and the lock is released',
      bodyError is FormatException && left.first[0] == 0);
  await Db.close();
  print('\nALL PASSED');
  exit(0);
}
