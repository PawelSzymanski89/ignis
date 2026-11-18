// Statyki /assets/ przez dyspozytor obsluz: ETag ze skrótu treści, 304 na If-None-Match, gzip dla tekstu — bez bazy.
import 'dart:io';

import '../lib/engine/ignis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  final t = Directory.systemTemp.createTempSync('statyki');
  File('${t.path}/a.css').writeAsStringSync('body{color:red}' * 200);
  File('${t.path}/b.png').writeAsBytesSync(List.filled(500, 7));
  final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  srv.listen((req) => dispatch(req, [t.path]));
  final k = HttpClient()..autoUncompress = false;
  Future<(HttpClientResponse, List<int>)> fetch(String p, {String? etag, bool gz = true}) async {
    final r = await k.get('127.0.0.1', srv.port, p);
    r.headers.set(HttpHeaders.acceptEncodingHeader, gz ? 'gzip, br' : 'identity');
    if (etag != null) r.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
    final o = await r.close();
    return (o, (await o.toList()).expand((x) => x).toList());
  }

  try {
    final (a, body) = await fetch('/assets/a.css');
    final etag = a.headers.value(HttpHeaders.etagHeader);
    check('200 z ETag', a.statusCode == 200 && etag != null && RegExp(r'^W/"[0-9a-f]{10}"$').hasMatch(etag));
    check('css spakowany gzipem i poprawny', a.headers.value('content-encoding') == 'gzip' &&
        String.fromCharCodes(gzip.decode(body)) == 'body{color:red}' * 200 && body.length < 3000);
    final (a2, body2) = await fetch('/assets/a.css');
    check('drugie pobranie: te same bajty gzip (z pamięci)',
        a2.headers.value('content-encoding') == 'gzip' && body2.length == body.length &&
            String.fromCharCodes(gzip.decode(body2)) == 'body{color:red}' * 200);
    final (n, empty) = await fetch('/assets/a.css', etag: etag);
    check('If-None-Match → 304 bez treści', n.statusCode == 304 && empty.isEmpty);
    final (without, plain) = await fetch('/assets/a.css', gz: false);
    check('bez Accept-Encoding: gzip — jawny tekst', without.headers.value('content-encoding') == null && plain.length == 3000);
    final (png, _) = await fetch('/assets/b.png');
    check('obraz bez gzip', png.statusCode == 200 && png.headers.value('content-encoding') == null);
    final (missing, _) = await fetch('/assets/nie-ma.css');
    check('brak pliku → 404', missing.statusCode == 404);
  } finally {
    k.close();
    await srv.close();
    t.deleteSync(recursive: true);
  }
}
