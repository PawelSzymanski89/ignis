// HARD-L.8: nodes on a runtime role without table ownership (grants from SECURITY.md) start with
// IGNIS_SCHEMA=validate and no warning; the table owner outside `update` gets a start-up warning.
// Run: tool/pg_test.sh test/runtime_role_pg_test.dart (creates the role ignis_rt, owning nothing).
import 'dart:io';

import 'package:ignis/ignis.dart';
// ignore: unused_import
import 'package:ignis/entities.dart';

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
Future<ProcessResult> node(String user, String password, String mode) => Process.run(
    Platform.resolvedExecutable, [Platform.script.toFilePath(), 'node'],
    environment: {'IGNIS_DB_USER': user, 'IGNIS_DB_PASS': password, 'IGNIS_SCHEMA': mode});

Future<void> main(List<String> a) async {
  if (Platform.environment['IGNIS_DB_HOST'] == null) {
    print('  skipped — no IGNIS_DB_HOST (tool/pg_test.sh)');
    return;
  }
  EntityRegistry.build();
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
  r = await node('ignis_rt', 'ignisrt', 'update');
  check('runtime role cannot migrate (IGNIS_SCHEMA=update fails)', r.exitCode != 0);

  final owner = Platform.environment['IGNIS_DB_USER']!, ownerPassword = Platform.environment['IGNIS_DB_PASS']!;
  r = await node(owner, ownerPassword, 'validate');
  check('table owner with IGNIS_SCHEMA=validate starts', r.exitCode == 0);
  check('table owner outside update — warning in the log', '${r.stdout}${r.stderr}'.contains(warning));
  r = await node(owner, ownerPassword, 'update');
  check('table owner migrating (update) — no warning', r.exitCode == 0 && !'${r.stdout}${r.stderr}'.contains(warning));
  print('\nALL PASSED');
  exit(0);
}
