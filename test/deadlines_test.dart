// Termin żądania (Engine.chronione → deadline) i walidacja Host przed szukaniem usługi — bez bazy.
import 'dart:async';
import 'dart:io';

import '../lib/engine/annotations.dart';
import '../lib/engine/engine.dart';
import '../lib/engine/tenant.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  for (final h in ['a b.example', 'x' * 300, 'ex_ample.com', '-zly.example', 'a..b', '<script>', 'é.example']) {
    check('Host „${h.length > 20 ? '${h.substring(0, 20)}…' : h}” odrzucony bez bazy', await Tenants.fromHost(h) == null);
  }

  // FIX-22: zwykła trasa ma krótki termin, upload (maksCiala) i nieznana ścieżka przed dopasowaniem — pełny
  check('trasa bez maksCiala → terminKrotki', Engine.routeDeadline(const Page('/x')) == Engine.shortDeadline);
  check('trasa z maksCiala → terminZadania',
      Engine.routeDeadline(const Page('/x', maxBody: 1)) == Engine.requestDeadline);
  check('domyślnie 15 s i 120 s', Engine.shortDeadline.inSeconds == 15 && Engine.requestDeadline.inSeconds == 120);

  Engine.requestDeadline = const Duration(milliseconds: 500);
  final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  srv.listen((req) => Engine.guarded(req, () async {
        await req.drain<void>();
        req.response.write('ok');
        await req.response.close();
      }));

  // wolny klient: nagłówki z Content-Length, body nigdy nie przychodzi
  final s = await Socket.connect('127.0.0.1', srv.port);
  s.write('POST /x HTTP/1.1\r\nHost: a\r\nContent-Length: 1000\r\n\r\nabc');
  final closed = Completer<void>();
  s.listen((_) {}, onDone: closed.complete, onError: (_) => closed.complete());
  final elapsed = Stopwatch()..start();
  await closed.future.timeout(const Duration(seconds: 5));
  check('wolne body zerwane po terminie (${elapsed.elapsedMilliseconds} ms)', elapsed.elapsedMilliseconds < 3000);
  s.destroy();

  // keep-alive: drugie żądanie po upływie terminu pierwszego nie jest zrywane
  final k = HttpClient();
  final r1 = await (await k.get('127.0.0.1', srv.port, '/a')).close();
  await r1.drain<void>();
  await Future<void>.delayed(const Duration(milliseconds: 400));
  final r2 = await (await k.get('127.0.0.1', srv.port, '/b')).close();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  check('kolejne żądanie na tym samym połączeniu działa', r2.statusCode == 200 && await r2.transform(const SystemEncoding().decoder).join() == 'ok');
  k.close();
  await srv.close();
}
