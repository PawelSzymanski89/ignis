// IGNIS-053.11: the CSRF double-submit check compares the form token with the cookie in constant time
// (Signing.equal), and still accepts only an exact match. No database: technical + noDb route over loopback.
// Run: dart run test/csrf_compare_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:ignis/ignis.dart';

import 'registry_helper.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

class CsrfForm extends PageEngine {
  @override
  Future<bool> processData() async => respond(200, {'ok': true});
}

Future<void> main() async {
  final src = File('lib/engine/engine.dart').readAsStringSync();
  final body = src.substring(src.indexOf('static Future<bool> _checkCsrf('));
  final fn = body.substring(0, body.indexOf('\n  }\n'));
  check('_checkCsrf compares the token with Signing.equal', fn.contains('Signing.equal('));
  check('…not with == / != on the token', !RegExp(r"params\['csrf'\]\s*[!=]=").hasMatch(fn));

  PageRegistry.build(testRegistry(pages: [
    testPage(const Page('/csrf-x', technical: true, noDb: true, methods: ['POST']), CsrfForm.new),
  ]));
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () => Engine.handle(req)));
  final client = HttpClient();
  Future<int> post(String? cookie, String? field) async {
    final q = await client.open('POST', '127.0.0.1', server.port, '/csrf-x');
    q.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
    if (cookie != null) q.headers.set('cookie', '${Engine.csrfCookie}=$cookie');
    q.write(Uri(queryParameters: {'csrf': ?field}).query);
    final r = await q.close();
    await r.transform(utf8.decoder).join();
    return r.statusCode;
  }

  check('matching token → passes', await post('tok-053-abc', 'tok-053-abc') == 200);
  check('different token of the same length → 403', await post('tok-053-abc', 'tok-053-abd') == 403);
  check('prefix of the token → 403', await post('tok-053-abc', 'tok-053') == 403);
  check('empty field → 403', await post('tok-053-abc', '') == 403);
  check('no field → 403', await post('tok-053-abc', null) == 403);
  check('no cookie → 403', await post(null, 'tok-053-abc') == 403);
  client.close(force: true);
  await server.close(force: true);
  print('\nALL PASSED');
  exit(0);
}
