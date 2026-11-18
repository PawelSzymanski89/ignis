// Łagodne zamknięcie: nowe połączenia odrzucone, trwające żądanie dokończone, limit zrywa resztę (audyt B).
import 'dart:async';
import 'dart:io';

import '../lib/engine/shutdown.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<(HttpServer, Shutdown)> server(Duration delay) async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final z = Shutdown();
  s.listen((req) => z.track(() async {
        await Future.delayed(delay);
        req.response.write('gotowe');
        await req.response.close();
      }()));
  return (s, z);
}

Future<void> main() async {
  final (s, z) = await server(const Duration(milliseconds: 500));
  final client = HttpClient();
  final free = client.get('127.0.0.1', s.port, '/').then((r) => r.close()).then(
      (r) async => (r.statusCode, await r.transform(const SystemEncoding().decoder).join()));
  while (z.inFlight == 0) {
    await Future.delayed(const Duration(milliseconds: 10));
  }
  final port = s.port;
  final closed = z.close(s);
  await Future.delayed(const Duration(milliseconds: 50));
  var rejected = false;
  try {
    await (await HttpClient().get('127.0.0.1', port, '/')).close();
  } on SocketException {
    rejected = true;
  }
  check('nowe połączenie odrzucone', rejected);
  final (code, content) = await free;
  check('trwające żądanie dokończone', code == 200 && content == 'gotowe');
  check('zamknięcie czyste', await closed);

  final (s2, z2) = await server(const Duration(seconds: 5));
  final broken = client.get('127.0.0.1', s2.port, '/').then((r) => r.close()).then((_) => false, onError: (_) => true);
  while (z2.inFlight == 0) {
    await Future.delayed(const Duration(milliseconds: 10));
  }
  final t = Stopwatch()..start();
  check('po limicie zamknięcie wymuszone', !await z2.close(s2, limit: const Duration(milliseconds: 200)));
  check('limit dotrzymany', t.elapsedMilliseconds < 2000);
  check('wiszące żądanie zerwane', await broken);
  client.close(force: true);
  exit(0); // zwłoka wiszącego handlera trzymałaby proces 5 s
}
