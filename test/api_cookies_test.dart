// SEC-040.1: an `api: true` route does not receive the session / customer / CSRF cookies nor the Cookie header.
// No database: technical + noDb route over loopback.
// Run: dart run test/api_cookies_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:ignis/ignis.dart';

import 'registry_helper.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

@Page('/v1/cookies-x', api: true, technical: true, noDb: true, methods: ['GET'])
class CookiesApi extends PageEngine {
  @override
  Future<bool> processData() async => respond(200, {
        'session': cookie(Sessions.cookieName),
        'customer': cookie(CustomerAccounts.cookie),
        'csrf': cookie(Engine.csrfCookie),
        'other': cookie('pref'),
        'header': requestHeader('cookie'),
      });
}

Future<void> main() async {
  PageRegistry.build(testRegistry(pages: [
    testPage(const Page('/v1/cookies-x', api: true, technical: true, noDb: true, methods: ['GET']), CookiesApi.new),
  ]));
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () => Engine.handle(req)));
  final client = HttpClient();
  final q = await client.open('GET', '127.0.0.1', server.port, '/v1/cookies-x');
  q.headers.set('cookie',
      '${Sessions.cookieName}=s1; ${CustomerAccounts.cookie}=c1; ${Engine.csrfCookie}=t1; pref=dark');
  final r = await q.close();
  final j = jsonDecode(await r.transform(utf8.decoder).join()) as Map;
  check('200', r.statusCode == 200);
  check('session cookie not passed', j['session'] == null);
  check('customer cookie not passed', j['customer'] == null);
  check('csrf cookie not passed', j['csrf'] == null);
  check('other cookies stay', j['other'] == 'dark');
  check('Cookie header dropped', j['header'] == null);
  client.close(force: true);
  await server.close(force: true);
  print('\nALL PASSED');
  exit(0);
}
