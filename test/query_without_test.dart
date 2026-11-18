// PageEngine.parametryBez / zapytanieBez: linki „ta sama strona, inny filtr” zachowują parametry adresu
// (np. id szczegółu), podmieniają wskazane i nigdy nie niosą pól formularza (csrf, hasła).
import 'package:ignis/ignis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

class TestPage extends PageEngine {}

void main() {
  final s = TestPage()
    ..bind(
      method: 'POST',
      meta: const Page('/app/campaigns/view'),
      params: {'tenant': 'acme', 'id': 'k 1&x', 'range': '7d', 'csrf': 'tajny', 'haslo': 'Sekret'},
      cookies: const {},
      context: const TenantContext(service: 0, name: 'x', domain: 'x.test', panel: false, active: true),
      query: {'tenant': 'acme', 'id': 'k 1&x', 'range': '7d'},
    );
  check('pomija wskazane, zachowuje id', s.paramsWithout(['range', 'tenant']).keys.toList().join(',') == 'id');
  check('pola formularza nie trafiają do linku',
      !s.paramsWithout(const []).containsKey('csrf') && !s.paramsWithout(const []).containsKey('haslo'));
  check('kodowanie wartości', s.queryWithout(['range', 'tenant']) == '&id=k+1%26x');
  check('nic nie zostaje → pusty dopisek', s.queryWithout(['range', 'tenant', 'id']).isEmpty);
  final noQuery = TestPage()
    ..bind(
      method: 'GET',
      meta: const Page('/x'),
      params: {'a': '1'},
      cookies: const {},
      context: const TenantContext(service: 0, name: 'x', domain: 'x.test', panel: false, active: true),
    );
  check('bez mapy zapytania (testy, stary bind) — pusto', noQuery.queryWithout(const []).isEmpty);
  print('zapytanie_bez_test: OK');
}
