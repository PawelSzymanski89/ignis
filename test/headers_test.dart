// Domyślne nagłówki bezpieczeństwa (Engine.chronione / stronaBledu) i brak cache dla HTML stron — bez bazy.
import 'dart:io';

import '../lib/engine/annotations.dart';
import '../lib/engine/engine.dart';
import '../lib/engine/ignis.dart';
import '../lib/engine/page_engine.dart';
import '../lib/engine/tenant.dart';

class _TestPage extends PageEngine {}

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  srv.listen((req) => Engine.guarded(req, () async {
        if (req.uri.path == '/blad') return Engine.errorPage(req.response, 404, 'not_found');
        await dispatch(req, [Directory.systemTemp.path]);
      }));
  final k = HttpClient();
  Future<HttpHeaders> headerValues(String p) async {
    final o = await (await k.get('127.0.0.1', srv.port, p)).close();
    await o.drain<void>();
    return o.headers;
  }

  for (final p in ['/blad', '/assets/nie-ma.css']) {
    final h = await headerValues(p);
    check('$p: nosniff, Referrer-Policy, X-Frame-Options SAMEORIGIN',
        h.value('x-content-type-options') == 'nosniff' &&
            h.value('referrer-policy') == 'strict-origin-when-cross-origin' &&
            h.value('x-frame-options') == 'SAMEORIGIN');
    check('$p: HSTS domyślnie wyłączony', h.value('strict-transport-security') == null);
    check('$p: COOP same-origin i Permissions-Policy',
        h.value('cross-origin-opener-policy') == 'same-origin' && h.value('permissions-policy') != null);
  }
  check('strona błędu: CSP w nagłówku z frame-ancestors',
      (await headerValues('/blad')).value('content-security-policy')!.contains("frame-ancestors 'self'"));
  check('IGNIS-052.4: strona błędu HTML — CORP same-origin',
      (await headerValues('/blad')).value('cross-origin-resource-policy') == 'same-origin');
  check('IGNIS-052.4: zasób statyczny bez CORP',
      (await headerValues('/assets/nie-ma.css')).value('cross-origin-resource-policy') == null);
  k.close();
  await srv.close();

  PageEngine page() => _TestPage()
    ..bind(method: 'GET', meta: const Page('/x'), params: const {}, cookies: const {},
        context: const TenantContext(service: 0, name: 'x', domain: 'x.test', panel: true, active: true));
  final html = <String, List<String>>{};
  final hh = _Headers(html);
  Engine.htmlHeaders(hh, page());
  check('HTML: no-store, CSP i Vary: HX-Request',
      html['cache-control']?.single == 'no-store' && html['content-security-policy']?.single == Engine.csp &&
          html['vary']!.contains('HX-Request, X-Ignis-Live'));
  check('IGNIS-052.4: HTML — Cross-Origin-Resource-Policy same-origin',
      html['cross-origin-resource-policy']?.single == 'same-origin');
  String? Function(String) z(Map<String, String> m) => (n) => m[n];
  check('FIX-48: X-Ignis-Live i HX-Request → sam fragment, zwykłe wejście → pełny layout',
      Engine.layoutFor(z({'X-Ignis-Live': '1'})) == '_fragment.html' &&
          Engine.layoutFor(z({'HX-Request': 'true'})) == '_fragment.html' &&
          Engine.layoutFor(z({})) == '_layout.html');
  check('FIX-48: na_zywo.js — co najmniej 5 s', File('web/ignis/live.js').readAsStringSync().contains('Math.max(5,'));
  final custom = page()..header('Cache-Control', 'private, max-age=60');
  html.clear();
  Engine.htmlHeaders(hh, custom);
  check('własny Cache-Control strony zostaje', html['cache-control'] == null);
  final js = page()..json({'a': 1});
  html.clear();
  Engine.htmlHeaders(hh, js);
  check('JSON: domyślnie no-store, bez CSP i Vary',
      html['cache-control']?.single == 'no-store' && html['content-security-policy'] == null && html['vary'] == null &&
          html['cross-origin-resource-policy'] == null);
}

class _Headers implements HttpHeaders {
  _Headers(this.m);
  final Map<String, List<String>> m;
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) => m[name.toLowerCase()] = ['$value'];
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) =>
      (m[name.toLowerCase()] ??= []).add('$value');
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
