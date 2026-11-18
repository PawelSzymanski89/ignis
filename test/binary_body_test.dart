// @Page(api: true, binarne: true, maksCiala: N): bajty body bez dekodowania utf8, limit trasy na łączu i po gzip.
// Wymaga Postgresa (Engine.handle bierze połączenie): IGNIS_DB_HOST/PORT/USER/PASS/NAME.
import 'dart:convert';
import 'dart:io';

import 'package:ignis/ignis.dart';
// ignore: unused_import
import 'package:ignis/pages.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

@Page('/v1/test-binarne', api: true, technical: true, methods: ['POST'], binary: true, maxBody: 3 * 1024 * 1024)
class ApiBinary extends PageEngine {
  @override
  Future<bool> processData() async => respond(200, {'n': bodyBytes.length, 'pierwszy': bodyBytes.first, 'text': body});
}

Future<void> main() async {
  if (Platform.environment['IGNIS_DB_HOST'] == null) {
    print('  pominięte — brak IGNIS_DB_HOST (Engine.handle bierze połączenie z Postgresa)');
    return;
  }
  PageRegistry.build();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () => dispatch(req, const [])));
  final client = HttpClient();

  Future<(int, String)> send(List<int> b, {bool gz = false}) async {
    final z = await client.open('POST', '127.0.0.1', server.port, '/v1/test-binarne');
    z.headers.host = 'localhost';
    if (gz) z.headers.set('content-encoding', 'gzip');
    try {
      z.add(gz ? gzip.encode(b) : b);
      final r = await z.close();
      return (r.statusCode, await r.transform(utf8.decoder).join());
    } on HttpException {
      // serwer odpowiada 413 i nie czyta reszty — klient w trakcie wysyłania dostaje zerwane połączenie
      return (-1, '');
    }
  }

  final large = List.filled(2500 * 1024, 0xff);
  final (k1, t1) = await send(large);
  check('2,5 MB binarnie (powyżej domyślnych 2 MB) → bajty bez zmian, cialo puste',
      k1 == 200 && jsonDecode(t1)['n'] == large.length && jsonDecode(t1)['pierwszy'] == 255 && jsonDecode(t1)['text'] == '');
  final (k2, _) = await send(List.filled(3 * 1024 * 1024 + 1, 1));
  check('ponad maksCiala na łączu → 413 (albo zerwane połączenie)', k2 == 413 || k2 == -1);
  final (k3, _) = await send(List.filled(4 * 1024 * 1024, 0), gz: true);
  check('gzip rozpakowany ponad maksCiala → 413', k3 == 413);
  final (k4, t4) = await send([7, 0, 1], gz: true);
  check('gzip w limicie → rozpakowane bajty', k4 == 200 && jsonDecode(t4)['n'] == 3 && jsonDecode(t4)['pierwszy'] == 7);
  client.close(force: true);
  await server.close(force: true);
  exit(0); // pula Postgresa trzyma proces
}
