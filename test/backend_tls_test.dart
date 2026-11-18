// SEC-A-18: tryby TLS do Postgresa z IGNIS_DB_SSL — verify-full weryfikuje certyfikat, literówka nie wyłącza TLS po cichu.
import 'package:ignis/engine/db.dart';
import 'package:postgres/postgres.dart' show SslMode;

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  check('brak = disable', Db.sslMode(null) == SslMode.disable);
  check('require = szyfrowanie bez weryfikacji', Db.sslMode('require') == SslMode.require);
  check('verify-full = SslMode.verifyFull', Db.sslMode('verify-full') == SslMode.verifyFull);
  Object? error;
  try {
    Db.sslMode('verify_full');
  } on StateError catch (e) {
    error = e;
  }
  check('literówka przerywa start (nie spada na disable)', error != null);
}
