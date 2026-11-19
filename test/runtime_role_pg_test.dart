// HARD-L.8: nodes on a runtime role without table ownership (grants from SECURITY.md) start with
// IGNIS_SCHEMA=validate and no warning; the table owner outside `update` gets a start-up warning.
// Run: tool/pg_test.sh test/runtime_role_pg_test.dart (creates the role ignis_rt, owning nothing).
import 'dart:io';

import 'package:ignis/ignis.dart';
// ignore: unused_import
import 'package:ignis/entities.dart';
import 'package:ignis/ignis_registry.g.dart';
import 'package:postgres/postgres.dart' show ServerException;
import 'pg_guard.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

/// The grant block from SECURITY.md ("Runtime database role"), with the test role names.
const grants = '''
GRANT USAGE ON SCHEMA public TO ignis_rt;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ignis_rt;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO ignis_rt;
ALTER DEFAULT PRIVILEGES FOR ROLE ignis_app IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ignis_rt;
ALTER DEFAULT PRIVILEGES FOR ROLE ignis_app IN SCHEMA public GRANT USAGE ON SEQUENCES TO ignis_rt;
''';

const warning = 'owns the engine tables';

/// Child: schema sync + seed as a node would run them at start-up, then a write under RLS.
Future<ProcessResult> node(String user, String password, String mode,
        {bool requireRuntimeRole = false, String? requireValue}) =>
    Process.run(
    Platform.resolvedExecutable, [Platform.script.toFilePath(), 'node'],
    environment: {
      'IGNIS_DB_USER': user,
      'IGNIS_DB_PASS': password,
      'IGNIS_SCHEMA': mode,
      if (requireRuntimeRole || requireValue != null) 'IGNIS_REQUIRE_RUNTIME_ROLE': requireValue ?? '1',
    });

Future<void> main(List<String> a) async {
  if (skipDestructive()) return;
  EntityRegistry.build(ignisRegistry);
  if (a.firstOrNull == 'attack') {
    // what a compromised node on the runtime role would try: drop/alter the isolation itself
    final codes = <String>[];
    await Db.asSystemSession(() async {
      final c = await Db.connect();
      for (final sql in [
        'DROP POLICY ${a[1]} ON users',
        'ALTER TABLE users DISABLE ROW LEVEL SECURITY',
        'ALTER TABLE users NO FORCE ROW LEVEL SECURITY',
        'DROP TABLE audit_log',
      ]) {
        try {
          await c.execute(sql);
          codes.add('passed');
        } on ServerException catch (e) {
          codes.add(e.code ?? '?');
        }
      }
    });
    stdout.write(codes.join(','));
    exit(0);
  }
  if (a.isNotEmpty) {
    await Schema.sync();
    await Seed.seed();
    await Db.asSystem(() async => (await Db.connect()).execute("SELECT count(*) FROM users"));
    await Db.close();
    stdout.writeln('STARTED');
    exit(0);
  }
  await Schema.sync();
  await Seed.seed();
  await Db.asSystemSession(() async {
    final c = await Db.connect();
    for (final s in grants.trim().split(';\n')) {
      await c.execute(s.replaceAll(';', ''));
    }
  });
  await Db.close();

  var r = await node('ignis_rt', 'ignisrt', 'validate');
  check('runtime role with DML grants starts with IGNIS_SCHEMA=validate', r.exitCode == 0 && '${r.stdout}'.contains('STARTED'));
  check('runtime role — no ownership warning', !'${r.stdout}${r.stderr}'.contains(warning));
  r = await node('ignis_rt', 'ignisrt', 'validate', requireRuntimeRole: true);
  check('HARD-L.13.8: runtime role with IGNIS_REQUIRE_RUNTIME_ROLE=1 starts', r.exitCode == 0 && '${r.stdout}'.contains('STARTED'));
  r = await node('ignis_rt', 'ignisrt', 'update');
  check('runtime role cannot migrate (IGNIS_SCHEMA=update fails)', r.exitCode != 0);
  check('…with insufficient_privilege (42501)', '${r.stdout}${r.stderr}'.contains('42501'));
  r = await Process.run(Platform.resolvedExecutable, [Platform.script.toFilePath(), 'attack', 'ignis_tenant'],
      environment: {'IGNIS_DB_USER': 'ignis_rt', 'IGNIS_DB_PASS': 'ignisrt'});
  check('runtime role: DROP POLICY, DISABLE/NO FORCE RLS and DROP TABLE all refused with 42501 (${r.stdout})',
      r.stdout == '42501,42501,42501,42501');
  final policies = await Db.asSystem(() async => (await (await Db.connect())
          .execute("SELECT count(*) FROM pg_policies WHERE tablename = 'users' AND policyname = 'ignis_tenant'"))
      .first[0]);
  check('…and the policy is still there', policies == 1);
  await Db.close();

  final owner = Platform.environment['IGNIS_DB_USER']!, ownerPassword = Platform.environment['IGNIS_DB_PASS']!;
  r = await node(owner, ownerPassword, 'validate');
  check('table owner with IGNIS_SCHEMA=validate starts', r.exitCode == 0);
  check('table owner outside update — warning in the log', '${r.stdout}${r.stderr}'.contains(warning));
  r = await node(owner, ownerPassword, 'validate', requireRuntimeRole: true);
  check('HARD-L.13.8: table owner with IGNIS_REQUIRE_RUNTIME_ROLE=1 → refused with StateError',
      r.exitCode != 0 && !'${r.stdout}'.contains('STARTED') &&
          '${r.stderr}'.contains('Bad state: IGNIS_REQUIRE_RUNTIME_ROLE=1'));
  // HARD-L.14.4: the check runs before Schema sync — a refused owner node changes no schema
  Future<bool> hasColumn() async => (await Db.asSystem(() async => (await (await Db.connect()).execute(
          "SELECT count(*) FROM information_schema.columns WHERE table_name = 'users' AND column_name = 'last_login'"))
      .first[0])) == 1;
  await Db.asSystemSession(() async => (await Db.connect()).execute('ALTER TABLE users DROP COLUMN last_login'));
  r = await node(owner, ownerPassword, 'update', requireRuntimeRole: true);
  check('table owner + IGNIS_SCHEMA=update + IGNIS_REQUIRE_RUNTIME_ROLE=1 → refused',
      r.exitCode != 0 && '${r.stderr}'.contains('Bad state: IGNIS_REQUIRE_RUNTIME_ROLE=1'));
  check('…before any DDL (the missing column was not added)', !await hasColumn());
  r = await node('ignis_rt', 'ignisrt', 'validate', requireValue: 'true');
  check('IGNIS_REQUIRE_RUNTIME_ROLE other than empty / "1" → refused',
      r.exitCode != 0 && '${r.stderr}'.contains('IGNIS_REQUIRE_RUNTIME_ROLE must be empty or 1'));
  await Db.close();
  r = await node(owner, ownerPassword, 'update');
  check('…the migrating owner adds the column back', r.exitCode == 0 && await hasColumn());
  r = await node('ignis_rt', 'ignisrt', 'validate', requireValue: '');
  check('IGNIS_REQUIRE_RUNTIME_ROLE empty = off', r.exitCode == 0 && '${r.stdout}'.contains('STARTED'));
  check('table owner migrating (update) — no warning', r.exitCode == 0 && !'${r.stdout}${r.stderr}'.contains(warning));
  print('\nALL PASSED');
  exit(0);
}
