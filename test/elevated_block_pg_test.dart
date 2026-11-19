// HARD-L.2: elevated blocks (Db.asSystem / Db.asPlatform) inside a request transaction. Overlapping blocks
// must not leave the request elevated, release()/commit() inside a block is refused, and an error in the
// block body is not masked by restoring the context.
// Run: tool/pg_test.sh test/elevated_block_pg_test.dart
import 'dart:async';
import 'dart:io';

import 'package:ignis/engine/db.dart';
import 'package:ignis/engine/orm.dart';
import 'package:ignis/engine/schema.dart';
// ignore: unused_import
import 'package:ignis/entities.dart';
import 'package:postgres/postgres.dart' show ServerException;

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<Object?> q(String sql) async => (await (await Db.connect()).execute(sql)).first[0];
Future<int> count() async => await q("SELECT count(*) FROM settings WHERE key LIKE 'elev.%'") as int;
Future<void> pause(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

/// SQLSTATE of an INSERT into tenant 2 (in a savepoint), or null when it went through.
Future<String?> insertForeign() async {
  try {
    await (await Db.connect()).runTx((tx) => tx.execute(
        "INSERT INTO settings (id, key, value, service) VALUES ('elev.x@2', 'elev.x', '', 2)"));
    return null;
  } on ServerException catch (e) {
    return e.code;
  }
}

Future<void> main() async {
  if (Platform.environment['IGNIS_DB_HOST'] == null) {
    print('  skipped — no IGNIS_DB_HOST (tool/pg_test.sh)');
    return;
  }
  EntityRegistry.build();
  await Schema.sync();
  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute("DELETE FROM settings WHERE key LIKE 'elev.%'");
    await c.execute("INSERT INTO settings (id, key, value, service) VALUES ('elev.a@1', 'elev.a', '', 1), "
        "('elev.b@2', 'elev.b', '', 2)");
  });

  for (final (name, raise) in [('asSystem', Db.asSystem<int>), ('asPlatform', Db.asPlatform<int>)]) {
    late List<int> inside;
    late Object? after;
    late int visible;
    late Object? foreignInsert;
    await Db.inContext(1, () async {
      await q('SELECT 1');
      inside = await Future.wait([
        raise(() async {
          await pause(60);
          return count();
        }),
        () async {
          await pause(30);
          return raise(() async {
            await pause(60);
            return count();
          });
        }(),
      ]);
      after = await q("SELECT current_setting('ignis.service')");
      visible = await count();
      foreignInsert = await insertForeign();
    });
    check('$name: both overlapping blocks see every tenant', inside[0] == 2 && inside[1] == 2);
    check('$name: after the blocks the request context is back to the tenant', after == '1' && visible == 1);
    check('$name: insert into another tenant is refused after the blocks (42501)', foreignInsert == '42501');
  }
  check('nothing leaked into the foreign tenant',
      await Db.asSystem(() async => await q("SELECT count(*) FROM settings WHERE id = 'elev.x@2'")) == 0);

  check('nested blocks restore the outer context', await Db.inContext(1, () async {
    await q('SELECT 1');
    final inner = await Db.asSystem(() async {
      final p = await Db.asPlatform(() async => await q("SELECT current_setting('ignis.service')"));
      return (p, await q("SELECT current_setting('ignis.service')"));
    });
    return (inner, await q("SELECT current_setting('ignis.service')"));
  }) == (('0', '*'), '1'));

  // a future started in a block but running after it inherits the zone of the finished block: it must not
  // restore that block's '*' when it ends
  late Object? inLate, afterLate, lateForeign;
  await Db.inContext(1, () async {
    await q('SELECT 1');
    await Db.asSystem(() async {
      await q('SELECT 1');
      unawaited(Future.delayed(const Duration(milliseconds: 30),
          () => Db.asPlatform(() async => inLate = await q("SELECT current_setting('ignis.service')"))));
    });
    await pause(100);
    afterLate = await q("SELECT current_setting('ignis.service')");
    lateForeign = await insertForeign();
  });
  check('a block outliving its parent block runs raised', inLate == '0');
  check('… and then the request context is the tenant again', afterLate == '1' && lateForeign == '42501');

  check(
      'parallel nested blocks (Future.wait) both see their own context, then the outer one returns',
      await Db.inContext(1, () async {
        await q('SELECT 1');
        final r = await Db.asSystem(() async {
          final both = await Future.wait([
            for (final ms in [60, 10])
              Db.asPlatform(() async {
                await pause(ms);
                return q("SELECT current_setting('ignis.service')");
              }),
          ]);
          return (both, await q("SELECT current_setting('ignis.service')"));
        });
        return (r.$1.join(','), r.$2, await q("SELECT current_setting('ignis.service')"));
      }) ==
          ('0,0', '*', '1'));

  // a block awaiting a future (created outside it) that itself waits for the queue: StateError, not a hang
  Object? deadlock;
  final watch = Stopwatch()..start();
  try {
    await Db.inContext(1, () async {
      await q('SELECT 1');
      final outside = Completer<void>();
      final waiting = outside.future.then((_) => Db.asSystem(() => q('SELECT 1')));
      await Db.asSystem(() async {
        outside.complete();
        await waiting;
      });
    });
  } catch (e) {
    deadlock = e;
  }
  check('a deadlocked elevated block ends with StateError (${watch.elapsed.inSeconds} s)',
      deadlock is StateError && '$deadlock'.contains('waited'));

  for (final (name, end) in [('release', Db.release), ('commit', Db.commit)]) {
    Object? error;
    try {
      await Db.inContext(1, () async {
        await q('SELECT 1');
        await Db.asSystem(() async {
          await q('SELECT 1');
          await end();
        });
      });
    } catch (e) {
      error = e;
    }
    check('Db.$name inside an elevated block → StateError', error is StateError && '$error'.contains('$name'));
  }

  Object? error;
  try {
    await Db.inContext(1, () async {
      await q('SELECT 1');
      await Db.asSystem(() => q('SELECT 1/0'));
    });
  } catch (e) {
    error = e;
  }
  check('an error in the block body is not masked (22012, not 25P02)', error is ServerException && error.code == '22012');

  await Db.asSystem(() async => (await Db.connect()).execute("DELETE FROM settings WHERE key LIKE 'elev.%'"));
  await Db.close();
  print('\nALL PASSED');
  exit(0);
}
