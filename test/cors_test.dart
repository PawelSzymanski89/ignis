// Test CORS tras API (@Page(cors: true)): preflight OPTIONS przez prawdziwy HttpServer, bez bazy.
import 'dart:io';

import '../lib/engine/annotations.dart';
import '../lib/engine/engine.dart';
import '../lib/engine/page_engine.dart';
import '../lib/engine/tenant.dart';

class _TestPage extends PageEngine {}

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  const meta = Page('/v1/x', api: true, methods: ['POST'], cors: true);
  final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  srv.listen((req) async {
    await Engine.preflightWithGate(req.response.headers, meta, req.headers.value('origin'),
        req.headers.value('access-control-request-headers'), req.uri);
    req.response.statusCode = 204;
    await req.response.close();
  });
  final k = HttpClient();
  Future<HttpClientResponse> ask(String? origin) async {
    final r = await k.openUrl('OPTIONS', Uri.parse('http://127.0.0.1:${srv.port}/v1/x'));
    if (origin != null) r.headers.set('Origin', origin);
    r.headers.set('Access-Control-Request-Headers', 'content-type, x-app-tenant');
    return r.close();
  }

  final r = await ask('https://sklep.example');
  check('origin odbity', r.headers.value('access-control-allow-origin') == 'https://sklep.example');
  check('metody z @Page + OPTIONS', r.headers.value('access-control-allow-methods') == 'POST, OPTIONS');
  check('nagłówki z żądania', r.headers.value('access-control-allow-headers') == 'content-type, x-app-tenant');
  check('Vary: Origin', r.headers.value('vary') == 'Origin');
  final without = await ask(null);
  check('bez Origin — bez nagłówków CORS', without.headers.value('access-control-allow-origin') == null);
  check('domyślnie cors wyłączony', !const Page('/v1/y', api: true).cors);
  Uri? requestedUri;
  Engine.preflightOrigin = (o, u) async {
    requestedUri = u;
    return o == 'https://sklep.example';
  };
  final allowed = await ask('https://sklep.example');
  check('bramka wpuszcza origin z listy', allowed.headers.value('access-control-allow-origin') == 'https://sklep.example');
  check('bramka dostaje adres żądania', requestedUri?.path == '/v1/x');
  final foreign = await ask('https://obcy.example');
  check('bramka: obcy origin bez nagłówków CORS', foreign.statusCode == 204 &&
      foreign.headers.value('access-control-allow-origin') == null && foreign.headers.value('access-control-allow-methods') == null);
  Engine.preflightOrigin = null;
  k.close();
  await srv.close();

  final s = _TestPage()
    ..bind(method: 'POST', meta: meta, params: const {}, cookies: const {}, context: TenantContext.platformContext, headerValues: const {})
    ..allowOrigin('https://sklep.example');
  check('zezwolOrigin: origin, Vary i Retry-After czytelny dla skryptu (429/503)',
      s.headers['Access-Control-Allow-Origin'] == 'https://sklep.example' && s.headers['Vary'] == 'Origin' &&
          s.headers['Access-Control-Expose-Headers'] == 'Retry-After');
}
