// Configurable CSP: Engine.buildCsp merges app sources into the base, rejects unsafe values,
// and every HTML response carries the computed Engine.csp — no database.
import 'dart:io';

import '../lib/engine/engine.dart';
import '../lib/engine/ignis.dart';
import '../lib/engine/render.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

bool rejects(Map<String, List<String>> extra) {
  try {
    Engine.buildCsp(extra);
    return false;
  } on ArgumentError {
    return true;
  }
}

Future<void> main() async {
  const base = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
      "font-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; "
      "frame-ancestors 'self'";
  check('no config → base policy unchanged', Engine.buildCsp(const {}) == base && Engine.csp == base);

  final merged = Engine.buildCsp({
    'img-src': ['https://img.example.com', 'data:'],
    'font-src': ['https://fonts.example.com'],
    'script-src': ["'wasm-unsafe-eval'"],
    'worker-src': ['blob:'],
    'object-src': ['https://obj.example.com'],
  });
  check('merge: sources appended, duplicates skipped',
      merged.contains("img-src 'self' data: https://img.example.com;") &&
          merged.contains("font-src 'self' data: https://fonts.example.com;") &&
          merged.contains("script-src 'self' 'wasm-unsafe-eval';"));
  check('merge: new directive added, frame-ancestors stays last',
      merged.contains("worker-src blob:") && merged.endsWith("frame-ancestors 'self'"));
  check("merge: 'none' replaced by the added source", merged.contains('object-src https://obj.example.com;'));

  for (final (what, extra) in [
    ('unknown directive', {'img-scr': ['https://a.example']}),
    ('report-uri is not a source directive', {'report-uri': ['https://a.example']}),
    ('semicolon', {'img-src': ['https://a.example; script-src *']}),
    ('comma', {'img-src': ['https://a.example,https://b.example']}),
    ('newline', {'img-src': ['https://a.example\nX: 1']}),
    ('space inside a source', {'img-src': ['https://a.example https://b.example']}),
    ('stray quote', {'img-src': ["https://a.example'"]}),
    ('unknown keyword', {'img-src': ["'foo'"]}),
    ("'unsafe-inline' in script-src", {'script-src': ["'unsafe-inline'"]}),
    ("'unsafe-eval' in script-src", {'script-src': ["'unsafe-eval'"]}),
    ("'unsafe-eval' in script-src-elem", {'script-src-elem': ["'unsafe-eval'"]}),
  ]) {
    check('rejected: $what', rejects(extra));
  }

  Engine.csp = merged;
  check('layout <meta> gets the same policy without frame-ancestors',
      Engine.cspMeta == merged.substring(0, merged.lastIndexOf('; frame-ancestors')));

  final dir = Directory.systemTemp.createTempSync('ignis_csp');
  File('${dir.path}/page.html').writeAsStringSync('<p>x</p>');
  final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  srv.listen((req) => Engine.guarded(req, () async {
        if (req.uri.path == '/error') return Engine.errorPage(req.response, 404, 'not_found');
        await dispatch(req, [dir.path]);
      }));
  final k = HttpClient();
  for (final p in ['/error', '/assets/page.html']) {
    final o = await (await k.get('127.0.0.1', srv.port, p)).close();
    final body = await o.transform(const SystemEncoding().decoder).join();
    check('$p: HTML response carries the configured CSP header',
        o.headers.value('content-security-policy') == merged && body.isNotEmpty);
  }
  k.close();
  await srv.close();
  dir.deleteSync(recursive: true);
  check('layout renders the configured policy in <meta>',
      Renderer.render('_layout_bare.html', {}).contains('content="${Engine.cspMeta}"'));
}
