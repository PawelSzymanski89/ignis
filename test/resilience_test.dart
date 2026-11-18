// Wyjątek w obsłudze żądania nie kończy procesu; stronaBledu po wysłaniu nagłówków nie rzuca (audyt A#7).
import 'dart:async';
import 'dart:io';

import '../lib/engine/engine.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () async {
        switch (req.uri.path) {
          case '/rzuc':
            throw StateError('awaria w obsłudze');
          case '/w-tle':
            // nieawaitowany Future — bez strefy zabiłby proces
            Future(() => throw StateError('awaria w tle'));
            await Future.delayed(const Duration(milliseconds: 50));
            req.response.write('ok');
            await req.response.close();
          case '/po-naglowkach':
            req.response.write('poczatek');
            await req.response.flush();
            await Engine.errorPage(req.response, 500, 'server');
          default:
            req.response.write('zyje');
            await req.response.close();
        }
      }));
  final client = HttpClient();
  Future<(int, String)> fetch(String p) async {
    final r = await (await client.get('127.0.0.1', server.port, p)).close();
    return (r.statusCode, await r.transform(const SystemEncoding().decoder).join());
  }

  final (code, _) = await fetch('/rzuc');
  check('wyjątek → 500', code == 500);
  check('kolejne żądanie obsłużone', (await fetch('/')).$2 == 'zyje');
  await fetch('/w-tle');
  await Future.delayed(const Duration(milliseconds: 100));
  check('błąd w tle nie zabił procesu', (await fetch('/')).$2 == 'zyje');
  final (k2, t2) = await fetch('/po-naglowkach');
  check('stronaBledu po nagłówkach: status bez zmian, odpowiedź domknięta', k2 == 200 && t2 == 'poczatek');
  check('serwer nadal odpowiada', (await fetch('/')).$2 == 'zyje');
  client.close(force: true);
  await server.close(force: true);
}
