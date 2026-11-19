// HARD-L.13.2: `@Page(api: true)` / `cors: true` skip CSRF, so a page authenticated by cookie (AdminPage — panel
// session, CustomerPage — customer session) must not be one: PageRegistry.build() refuses to start. No database.
// Run: dart run test/api_cookie_auth_test.dart
import 'package:ignis/ignis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

@Page('/v1/customer-x', api: true, methods: ['POST'])
class CustomerApi extends CustomerPage {}

@Page('/v1/staff-x', api: true, cors: true, methods: ['POST'])
class StaffApi extends AdminPage {}

@Page('/customer-cors-x', cors: true, methods: ['POST'])
class CustomerCors extends CustomerPage {}

@Page('/admin/staff-cors-x', cors: true, methods: ['POST'])
class StaffCors extends AdminPage {}

@Page('/v1/plain-x', api: true, methods: ['POST'])
class PlainApi extends PageEngine {}

void main() {
  Object? error;
  try {
    PageRegistry.build();
  } catch (e) {
    error = e;
  }
  check('api: true on a cookie-authenticated page → StateError at start-up', error is StateError);
  final m = '$error';
  check('…naming the CustomerPage route', m.contains('/v1/customer-x') && m.contains('CustomerApi'));
  check('…and the AdminPage route', m.contains('/v1/staff-x') && m.contains('StaffApi'));
  check('cors: true alone (no api) on a CustomerPage → refused too', m.contains('/customer-cors-x (CustomerCors)'));
  check('cors: true alone (no api) on an AdminPage → refused too', m.contains('/admin/staff-cors-x (StaffCors)'));
  check('…but not a plain PageEngine API page', !m.contains('/v1/plain-x'));
  check('…telling what to do', m.contains('cookie') && m.contains('CSRF'));
  print('\nALL PASSED');
}
