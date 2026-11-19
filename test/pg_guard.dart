// Guard for destructive PostgreSQL tests (DROP/UPDATE/DDL on shared tables or roles). They may only run against
// the throwaway cluster that tool/pg_test.sh builds: it exports IGNIS_PG_TEST=1 and uses a database whose name
// looks like a test one. Pointed at any other database (e.g. the README no-DB loop with IGNIS_DB_HOST set) the
// test skips instead of rewriting real data.
import 'dart:io';

/// Returns true and prints a skip line when the current environment is not the dedicated test cluster.
bool skipDestructive() {
  final env = Platform.environment;
  if (env['IGNIS_DB_HOST'] == null) {
    print('  skipped — no IGNIS_DB_HOST (tool/pg_test.sh)');
    return true;
  }
  final dbName = env['IGNIS_DB_NAME'] ?? '';
  if (env['IGNIS_PG_TEST'] != '1' || !dbName.toLowerCase().contains('test')) {
    print('  skipped — destructive test; runs only under tool/pg_test.sh '
        '(IGNIS_PG_TEST=1 and a test database, got IGNIS_DB_NAME=$dbName)');
    return true;
  }
  return false;
}
