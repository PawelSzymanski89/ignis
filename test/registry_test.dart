// Strony aplikacji (spoza pakietu) są znajdowane przez PageRegistry.build() — bez bazy.
// Uruchomienie: dart run test/registry_test.dart
import 'package:ignis/ignis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

@Page('/test-aplikacji')
class AppPage extends PageEngine {}

void main() {
  PageRegistry.build();
  print('rejestr stron:');
  check('strona aplikacji zarejestrowana', PageRegistry.match('/test-aplikacji') != null);
  check('strony rdzenia z barrela też', PageRegistry.routes.contains('/admin/login'));
  print('WSZYSTKO OK');
}
