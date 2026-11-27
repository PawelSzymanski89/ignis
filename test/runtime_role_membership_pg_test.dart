// IGNIS-054.6: role MEMBERSHIP counts, not just the role's own attributes and inherited privileges.
// - a NOINHERIT member of the table owner can SET ROLE to it (and ALTER/DROP the RLS policies): with
//   IGNIS_REQUIRE_RUNTIME_ROLE=1 it is refused like the owner itself;
// - a member of a SUPERUSER / BYPASSRLS role can SET ROLE out of RLS: refused in every mode;
// - a plain runtime role still starts.
// Roles are cluster-wide: created here as the bootstrap superuser of tool/pg_test.sh (ig/ig, like rls_pg_test) and
// dropped at the end.
// Run: tool/pg_test.sh test/runtime_role_membership_pg_test.dart
import 'dart:io';

import 'package:ignis/ignis.dart';
// ignore: unused_import
import 'package:ignis/entities.dart';
import 'package:ignis/ignis_registry.g.dart';
import 'package:postgres/postgres.dart';
import 'pg_guard.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

/// Child: only the start-up schema checks (IGNIS_SCHEMA=none: no DDL, no reads needing DML grants).
Future<ProcessResult> node(String user, String password, {bool requireRuntimeRole = false}) => Process.run(
    Platform.resolvedExecutable, [Platform.script.toFilePath(), 'node'],
    environment: {
      'IGNIS_DB_USER': user,
      'IGNIS_DB_PASS': password,
      'IGNIS_SCHEMA': 'none',
      if (requireRuntimeRole) 'IGNIS_REQUIRE_RUNTIME_ROLE': '1',
    });

Future<void> main(List<String> a) async {
  if (skipDestructive()) return;
  EntityRegistry.build(ignisRegistry);
  if (a.isNotEmpty) {
    await Schema.sync();
    stdout.writeln('STARTED');
    exit(0);
  }
  await Schema.sync();
  final env = Platform.environment;
  final owner = env['IGNIS_DB_USER']!;
  final su = await Connection.open(
      Endpoint(host: env['IGNIS_DB_HOST']!, port: int.parse(env['IGNIS_DB_PORT']!), database: env['IGNIS_DB_NAME']!,
          username: 'ig', password: 'ig'),
      settings: const ConnectionSettings(sslMode: SslMode.disable));
  const roles = ['ignis_m_owner', 'ignis_m_bypass', 'ignis_m_super', 'ignis_x_bypass', 'ignis_x_super'];
  Future<void> drop() async {
    for (final r in roles) {
      if ((await su.execute(Sql.named('SELECT 1 FROM pg_roles WHERE rolname = @r'), parameters: {'r': r})).isNotEmpty) {
        await su.execute('DROP OWNED BY $r'); // the schema grant below
      }
      await su.execute('DROP ROLE IF EXISTS $r');
    }
  }

  await drop();
  try {
    await su.execute("CREATE ROLE ignis_m_owner LOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS PASSWORD 'mowner'");
    await su.execute('GRANT $owner TO ignis_m_owner');
    await su.execute('CREATE ROLE ignis_x_bypass NOLOGIN BYPASSRLS');
    await su.execute("CREATE ROLE ignis_m_bypass LOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS PASSWORD 'mbypass'");
    await su.execute('GRANT ignis_x_bypass TO ignis_m_bypass');
    await su.execute('CREATE ROLE ignis_x_super NOLOGIN SUPERUSER');
    await su.execute("CREATE ROLE ignis_m_super LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD 'msuper'");
    await su.execute('GRANT ignis_x_super TO ignis_m_super');
    // like a real runtime role (tool/runtime_role.sql); without USAGE current_schema() is NULL for the role, and a
    // schema recreated by an earlier test (migration_pg_test) has no USAGE for PUBLIC
    await su.execute('GRANT USAGE ON SCHEMA public TO ignis_m_owner, ignis_m_bypass, ignis_m_super');

    var r = await node('ignis_rt', 'ignisrt', requireRuntimeRole: true);
    check('plain runtime role + IGNIS_REQUIRE_RUNTIME_ROLE=1 starts', r.exitCode == 0 && '${r.stdout}'.contains('STARTED'));

    r = await node('ignis_m_owner', 'mowner', requireRuntimeRole: true);
    check('NOINHERIT member of the table owner + IGNIS_REQUIRE_RUNTIME_ROLE=1 → refused',
        r.exitCode != 0 && '${r.stderr}'.contains('Bad state: IGNIS_REQUIRE_RUNTIME_ROLE=1'));

    r = await node('ignis_m_bypass', 'mbypass');
    check('member of a BYPASSRLS role → refused, naming the role',
        r.exitCode != 0 && !'${r.stdout}'.contains('STARTED') && '${r.stderr}'.contains('ignis_x_bypass'));

    r = await node('ignis_m_super', 'msuper');
    check('member of a SUPERUSER role → refused, naming the role',
        r.exitCode != 0 && !'${r.stdout}'.contains('STARTED') && '${r.stderr}'.contains('ignis_x_super'));
  } finally {
    await drop();
    await su.close();
  }
  await Db.close();
  print('\nALL PASSED');
  exit(0);
}
