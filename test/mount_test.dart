// Montaż katalogu publicznego (Montaz/serwujMontaz) przez prawdziwy HttpServer, bez bazy.
import 'dart:io';

import '../lib/engine/ignis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  final catalog = Directory.systemTemp.createTempSync('montaz');
  File('${catalog.path}/sdk.js').writeAsStringSync('window.X=1;');
  Directory('${catalog.path}/0.1.0').createSync();
  File('${catalog.path}/0.1.0/sdk.js').writeAsStringSync('window.X=0;');
  File('${catalog.path}/../tajne-montaz.txt').writeAsStringSync('sekret');
  final m = Mount('/sdk/', catalog.path, immutable: (p) => RegExp(r'^\d+\.\d+\.\d+/').hasMatch(p));
  final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  srv.listen((req) => serveMount(req, m));
  final k = HttpClient();
  Future<(int, HttpHeaders, String)> fetch(String path, {String method = 'GET'}) async {
    final r = await (await k.openUrl(method, Uri.parse('http://127.0.0.1:${srv.port}$path'))).close();
    return (r.statusCode, r.headers, await r.transform(const SystemEncoding().decoder).join());
  }

  final (s, h, t) = await fetch('/sdk/sdk.js');
  check('plik z katalogu, typ JS', s == 200 && t == 'window.X=1;' && h.contentType?.mimeType == 'application/javascript');
  check('publiczny dla każdej strony (CORS *) i nosniff',
      h.value('access-control-allow-origin') == '*' && h.value('x-content-type-options') == 'nosniff');
  check('adres bez wersji: krótki cache', h.value('cache-control') == 'public, max-age=300');
  final (s2, h2, t2) = await fetch('/sdk/0.1.0/sdk.js');
  check('adres z wersją: cache na rok, immutable',
      s2 == 200 && t2 == 'window.X=0;' && h2.value('cache-control') == 'public, max-age=31536000, immutable');
  check('brak pliku → 404', (await fetch('/sdk/nie.js')).$1 == 404);
  check('sam prefiks (katalog) → 404', (await fetch('/sdk/')).$1 == 404);
  check('wyjście poza katalog (%2e%2e) → 404', (await fetch('/sdk/%2e%2e/tajne-montaz.txt')).$1 == 404);
  check('POST → 405', (await fetch('/sdk/sdk.js', method: 'POST')).$1 == 405);
  final (s3, _, t3) = await fetch('/sdk/sdk.js', method: 'HEAD');
  check('HEAD bez treści', s3 == 200 && t3.isEmpty);
  // FIX-23: ETag i 304 jak w /assets/
  final etag = h.value(HttpHeaders.etagHeader);
  final rq = await k.getUrl(Uri.parse('http://127.0.0.1:${srv.port}/sdk/sdk.js'));
  rq.headers.set(HttpHeaders.ifNoneMatchHeader, etag!);
  final r304 = await rq.close();
  check('ETag i If-None-Match → 304', r304.statusCode == 304 && (await r304.toList()).isEmpty);
  k.close();
  await srv.close();
  File('${catalog.path}/../tajne-montaz.txt').deleteSync();
  catalog.deleteSync(recursive: true);
}
