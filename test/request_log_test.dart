// Log żądań: jedna linia (metoda, ścieżka bez query, kod, ms, id), X-Request-Id w odpowiedzi i w logu 500 (audyt B).
import 'dart:async';
import 'dart:io';

import '../lib/engine/engine.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  check('format linii', Engine.logLine('GET', '/v1/x', 404, 7, 'ab12') == 'Ignis GET /v1/x 404 7ms id=ab12');

  final lines = <String>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final client = HttpClient();
  String? idInZone;
  await IOOverrides.runZoned(() async {
    server.listen((req) => Engine.guarded(req, () async {
          idInZone = Engine.requestId;
          if (req.uri.path == '/rzuc') throw StateError('awaria');
          req.response.statusCode = 201;
          await req.response.close();
        }));
    Future<HttpClientResponse> fetch(String p) async {
      final rq = await client.get('127.0.0.1', server.port, p);
      rq.headers.set('Authorization', 'Bearer TAJNE');
      rq.cookies.add(Cookie('sesja', 'CIASTKO'));
      final r = await rq.close();
      await r.drain<void>();
      return r;
    }

    final r = await fetch('/v1/zdarzenia?token=SEKRET');
    await Future.delayed(const Duration(milliseconds: 50));
    final id = r.headers.value('X-Request-Id') ?? '';
    check('X-Request-Id w odpowiedzi', RegExp(r'^[0-9a-f]{16}$').hasMatch(id));
    check('id dostępne w strefie żądania', idInZone == id);
    final line = lines.singleWhere((l) => l.contains('id=$id'));
    check('linia: metoda, ścieżka bez query, kod, czas',
        RegExp(r'^Ignis GET /v1/zdarzenia 201 \d+ms id=').hasMatch(line));
    check('bez query, autoryzacji i ciasteczek',
        !lines.join().contains('SEKRET') && !lines.join().contains('TAJNE') && !lines.join().contains('CIASTKO'));

    final r5 = await fetch('/rzuc');
    await Future.delayed(const Duration(milliseconds: 50));
    final id5 = r5.headers.value('X-Request-Id') ?? '';
    check('500 ma X-Request-Id', r5.statusCode == 500 && id5.isNotEmpty);
    check('log błędu 500 z id', lines.any((l) => l.startsWith('Ignis 500 id=$id5:')));
    check('linia żądania 500', lines.any((l) => l.startsWith('Ignis GET /rzuc 500 ') && l.endsWith('id=$id5')));
  }, stdout: () => _Collector(lines), stderr: () => _Collector(lines));
  client.close(force: true);
  await server.close(force: true);
}

class _Collector implements Stdout {
  _Collector(this.lines);
  final List<String> lines;
  @override
  void writeln([Object? o = '']) => lines.add('$o');
  @override
  dynamic noSuchMethod(Invocation i) => null;
}
