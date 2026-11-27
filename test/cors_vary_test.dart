// IGNIS-054.5: a cors page answering HTML sends one Vary with every value — allowOrigin's `Origin` and the HTML
// `HX-Request, X-Ignis-Live`, and a Vary the page set itself — instead of one overwriting another. The preflight keeps
// a Vary set before it too.
// No database: technical + noDb route over loopback.
// Run: dart run test/cors_vary_test.dart
import 'dart:io';

import 'package:ignis/ignis.dart';

import 'registry_helper.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

class CorsHtml extends PageEngine {
  @override
  Future<bool> processData() async {
    header('Vary', 'Accept-Language');
    allowOrigin('https://shop.example');
    write('<p>hi</p>');
    return false;
  }
}

Future<void> main() async {
  const meta = Page('/v1/cors-vary-x', cors: true, technical: true, noDb: true, methods: ['GET']);
  PageRegistry.build(testRegistry(pages: [testPage(meta, CorsHtml.new)]));
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () => Engine.handle(req)));
  final client = HttpClient();
  final q = await client.open('GET', '127.0.0.1', server.port, '/v1/cors-vary-x');
  q.headers.set('origin', 'https://shop.example');
  final r = await q.close();
  await r.drain<void>();
  final vary = (r.headers['vary'] ?? const []).expand((v) => v.split(',')).map((v) => v.trim()).toList();
  print('  Vary: $vary');
  check('200, HTML', r.statusCode == 200 && r.headers.contentType?.mimeType == 'text/html');
  check('Vary contains Origin', vary.contains('Origin'));
  check('Vary contains HX-Request and X-Ignis-Live', vary.contains('HX-Request') && vary.contains('X-Ignis-Live'));
  check("the page's own Vary (Accept-Language) survives allowOrigin", vary.contains('Accept-Language'));
  check('each value once', vary.toSet().length == vary.length);
  client.close(force: true);
  await server.close(force: true);

  final h = _Headers()..add('Vary', 'Accept-Encoding');
  Engine.preflight(h, meta, 'https://shop.example', null);
  check('preflight adds Origin to a Vary already there', h.m['vary']!.join(',').contains('Accept-Encoding') &&
      h.m['vary']!.join(',').contains('Origin'));
  print('\nALL PASSED');
  exit(0);
}

class _Headers implements HttpHeaders {
  final m = <String, List<String>>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) => m[name.toLowerCase()] = ['$value'];
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) =>
      (m[name.toLowerCase()] ??= []).add('$value');
  @override
  dynamic noSuchMethod(Invocation i) => null;
}
