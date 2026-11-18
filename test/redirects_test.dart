// Przekierowania z Ignis.uruchom: 301 (przekierowania:) i 302 z / (stronaGlowna:) — przez dyspozytor obsluz, bez bazy.
import 'dart:io';

import 'package:ignis/ignis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  Ignis.redirects = {'/crashe': '/app/crashes'};
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () => dispatch(req, const [])));
  final client = HttpClient();
  final task = await client.open('GET', '127.0.0.1', server.port, '/crashe?tenant=a&range=7d');
  task.followRedirects = false;
  final r = await task.close();
  await r.drain<void>();
  check('stara ścieżka → 301', r.statusCode == 301);
  check('Location z nową ścieżką i tym samym query',
      r.headers.value('location') == '/app/crashes?tenant=a&range=7d');
  // FIX-32: cel żądania z hostem (`//obcy/…`, absolute-form) nie przenosi go do Location
  for (final target in ['//evil.example/crashe', 'http://evil.example/crashe']) {
    final so = await Socket.connect('127.0.0.1', server.port);
    so.write('GET $target HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n');
    final response = String.fromCharCodes(await so.fold<List<int>>([], (a, b) => a..addAll(b)));
    so.destroy();
    check('$target → Location bez obcego hosta', response.toLowerCase().contains('\r\nlocation: /app/crashes\r\n'));
  }
  Ignis.homePage = '/app/dashboard';
  final g = await (await client.open('GET', '127.0.0.1', server.port, '/')..followRedirects = false).close();
  await g.drain<void>();
  check('GET / → 302 na stronę główną aplikacji',
      g.statusCode == 302 && g.headers.value('location') == '/app/dashboard');
  client.close(force: true);
  await server.close(force: true);
}
