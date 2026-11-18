// FIX-16: zepsute %-kodowanie w query (`?q=%ff`) to 400 z domkniętą odpowiedzią, nie 500; zepsute Cookie nie wywraca żądania.
import 'dart:convert';
import 'dart:io';

import '../lib/engine/engine.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  // obsługa jak w Engine.handle: parametry z query i ciasteczka
  srv.listen((req) => Engine.guarded(req, () async {
        final p = req.uri.queryParameters;
        final c = req.cookies;
        req.response.write('ok ${p.length} ${c.length}');
        await req.response.close();
      }));
  Future<(String, bool)> task(String headerValues) async {
    final s = await Socket.connect('127.0.0.1', srv.port);
    s.write('$headerValues\r\nHost: localhost\r\nConnection: close\r\n\r\n');
    var closed = true;
    final response = await s.cast<List<int>>().transform(latin1.decoder).join()
        .timeout(const Duration(seconds: 5), onTimeout: () {
      closed = false;
      return '';
    });
    s.destroy();
    return (response.split('\r\n').first, closed);
  }

  for (final q in ['/x?q=%ff', '/x?lang=%ff', '/x?a=%e2%82']) {
    final (status, closed) = await task('GET $q HTTP/1.1');
    check('$q → 400 ($status), odpowiedź domknięta', status.contains(' 400 ') && closed);
  }
  final (ok, _) = await task('GET /x?q=%C5%BC HTTP/1.1');
  check('poprawne UTF-8 w query → 200', ok.contains(' 200 '));
  final (ck, ckz) = await task('GET /x HTTP/1.1\r\nCookie: a=b;;="');
  check('zepsute Cookie: nie 500 ($ck), odpowiedź domknięta', !ck.contains(' 500 ') && ckz);
  await srv.close(force: true);
}
