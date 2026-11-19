// HARD-L.12.3: destructive PostgreSQL tests run only on the throwaway cluster of tool/pg_test.sh. With IGNIS_DB_HOST
// set but no IGNIS_PG_TEST=1 (the README no-DB loop on a developer machine) or with a non-test database name they skip
// before touching anything. The host points at a closed port: a test that tried to connect would fail.
import 'dart:io';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  final pgTests = Directory('test').listSync().map((f) => f.path).where((p) => p.endsWith('_pg_test.dart')).toList()
    ..sort();
  final unguarded = [
    for (final p in pgTests)
      if (!File(p).readAsStringSync().contains('skipDestructive()') &&
          RegExp(r'DROP|DELETE|UPDATE|TRUNCATE|Schema\.sync').hasMatch(File(p).readAsStringSync()))
        p,
  ];
  check('every PostgreSQL test that changes data calls skipDestructive() ($unguarded)', unguarded.isEmpty);

  Future<String> run(String test, Map<String, String> env) async {
    final r = await Process.run(Platform.resolvedExecutable, ['run', test],
        environment: {'IGNIS_DB_HOST': '127.0.0.1', 'IGNIS_DB_PORT': '1', 'IGNIS_DB_PASS': 'x', ...env},
        includeParentEnvironment: false);
    return '${r.exitCode} ${r.stdout}${r.stderr}';
  }

  for (final t in ['test/schema_parallel_start_pg_test.dart', 'test/rekey_pg_test.dart', 'test/runtime_role_pg_test.dart']) {
    final out = await run(t, {'IGNIS_DB_NAME': 'ignistest'});
    check('$t without IGNIS_PG_TEST → skipped', out.startsWith('0 ') && out.contains('skipped — destructive test'));
  }
  final prod = await run('test/rekey_pg_test.dart', {'IGNIS_PG_TEST': '1', 'IGNIS_DB_NAME': 'ignis'});
  check('IGNIS_PG_TEST=1 with a non-test database name → skipped',
      prod.startsWith('0 ') && prod.contains('IGNIS_DB_NAME=ignis'));
  print('\nALL PASSED');
}
