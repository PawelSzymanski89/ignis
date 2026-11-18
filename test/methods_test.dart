// Test @Page(metody:) — lista dozwolonych metod HTTP (inne dostają 405), bez bazy.
import '../lib/engine/annotations.dart';
import '../lib/engine/engine.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  const postOnly = Page('/v1/x', api: true, methods: ['POST']);
  const every = Page('/x');
  check('POST dozwolony', Engine.methodAllowed(postOnly, 'POST'));
  check('wielkość liter metody bez znaczenia', Engine.methodAllowed(postOnly, 'post'));
  check('GET → 405', !Engine.methodAllowed(postOnly, 'GET'));
  check('PUT → 405', !Engine.methodAllowed(postOnly, 'PUT'));
  check('bez listy każda metoda', Engine.methodAllowed(every, 'DELETE'));
}
