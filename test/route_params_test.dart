// Trasy z segmentami {nazwa}: dopasowanie i wartości (bez serwera).
import '../lib/engine/registry.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  const w = '/v1/server/profiles/{identity}';
  check('pasuje i dekoduje %XX', PageRegistry.pathParams(w, '/v1/server/profiles/jan%40x.pl')?['identity'] == 'jan@x.pl');
  check('pusty segment nie pasuje', PageRegistry.pathParams(w, '/v1/server/profiles/') == null);
  check('więcej segmentów nie pasuje', PageRegistry.pathParams(w, '/v1/server/profiles/a/b') == null);
  check('inny stały segment nie pasuje', PageRegistry.pathParams(w, '/v1/server/profile/a') == null);
  check('zły %XX nie pasuje', PageRegistry.pathParams(w, '/v1/server/profiles/%E0%A4%A') == null);
  check('%2F w segmencie zostaje jednym segmentem', PageRegistry.pathParams(w, '/v1/server/profiles/a%2Fb')?['identity'] == 'a/b');
  check('dwa parametry', PageRegistry.pathParams('/a/{x}/b/{y}', '/a/1/b/2').toString() == '{x: 1, y: 2}');
  check('trasa bez parametrów: dokładna równość', PageRegistry.pathParams('/a/b', '/a/b')!.isEmpty &&
      PageRegistry.pathParams('/a/b', '/a/c') == null);
}
