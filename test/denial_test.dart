// PageEngine.odmowa — z niej silnik bierze wynik wpisu dziennika (ok/odmowa/blad); bez bazy.
import 'package:ignis/ignis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

class TestPage extends PageEngine {}

class Panel extends AdminPage {}

void main() {
  check('świeża strona — bez odmowy', !TestPage().denied);
  check('forbidden() → odmowa', (TestPage()..forbidden()).denied);
  check('unauthorized() → odmowa', (TestPage()..unauthorized()).denied);
  check('notFound() to nie odmowa', !(TestPage()..notFound()).denied);
  // flash w wroc() jest podpisany usługą z kontekstu (SEC-A-14)
  final p = Panel()
    ..meta = const Page('/admin/x')
    ..context = const TenantContext(service: 1, name: 'x', domain: 'x.test', panel: true, active: true);
  p.missingPermission('x.edit');
  check('brakUprawnienia() → odmowa', p.denied);
}
