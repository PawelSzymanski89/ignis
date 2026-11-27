// IGNIS-053.9: IGNIS_REQUIRE_BACKEND_TLS=1 (opt-in) turns the backend TLS warnings into a refused start; unset/empty
// changes nothing; any other value is itself an error. No database.
// Run: dart run test/require_backend_tls_test.dart
import 'package:ignis/ignis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  const plain = {'IGNIS_DB_HOST': 'db.internal', 'IGNIS_REDIS_HOST': '10.0.0.5'};
  const tls = {
    'IGNIS_DB_HOST': 'db.internal',
    'IGNIS_DB_SSL': 'verify-full',
    'IGNIS_REDIS_HOST': '10.0.0.5',
    'IGNIS_REDIS_TLS': '1',
  };
  check('unset — remote backends without TLS stay warnings only', Ignis.backendTlsError(plain) == null);
  check('empty — the same', Ignis.backendTlsError({...plain, 'IGNIS_REQUIRE_BACKEND_TLS': ''}) == null);
  final e = Ignis.backendTlsError({...plain, 'IGNIS_REQUIRE_BACKEND_TLS': '1'});
  check(
    '=1 with remote backends without TLS — refused, naming each backend',
    e != null && e.contains('IGNIS_REQUIRE_BACKEND_TLS') && e.contains('IGNIS_DB_SSL') && e.contains('IGNIS_REDIS_TLS'),
  );
  check(
    '=1 with IGNIS_DB_SSL=require on a remote host — refused (certificate not verified)',
    Ignis.backendTlsError({...tls, 'IGNIS_DB_SSL': 'require', 'IGNIS_REQUIRE_BACKEND_TLS': '1'}) != null,
  );
  check('=1 with TLS everywhere — accepted', Ignis.backendTlsError({...tls, 'IGNIS_REQUIRE_BACKEND_TLS': '1'}) == null);
  check(
    '=1 with loopback backends — accepted',
    Ignis.backendTlsError({'IGNIS_DB_HOST': '127.0.0.1', 'IGNIS_REQUIRE_BACKEND_TLS': '1'}) == null,
  );
  for (final bad in ['true', 'yes', '0', ' 1']) {
    final b = Ignis.backendTlsError({'IGNIS_REQUIRE_BACKEND_TLS': bad});
    check('"$bad" — refused as an invalid value', b != null && b.contains('IGNIS_REQUIRE_BACKEND_TLS'));
  }
  print('\nALL PASSED');
}
