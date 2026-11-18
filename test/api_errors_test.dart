// Błędy pod prefiksem stron `api: true` — JSON {"error": …} z kodem, nie strona HTML (audyt B).
import 'dart:convert';
import 'dart:io';

import 'package:ignis/ignis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

@Page('/v9/zdarzenia', api: true, methods: ['POST'])
class ApiTest extends PageEngine {}

Future<void> main() async {
  PageRegistry.build();
  check('strona api jest pod api', PageRegistry.underApi('/v9/zdarzenia'));
  check('nieznana ścieżka pod prefiksem api', PageRegistry.underApi('/v9/nie-ma'));
  check('sam prefiks bez segmentu to nie api', !PageRegistry.underApi('/v9'));
  check('panel nie jest api', !PageRegistry.underApi('/admin/nie-ma'));
  check('opis po angielsku', Engine.errorDescription(413) == 'payload too large' && Engine.errorDescription(503) == 'internal server error');

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () => Engine.handle(req)));
  final client = HttpClient();
  Future<(int, String?, String)> task(String method, String p) async {
    final r = await (await client.open(method, '127.0.0.1', server.port, p)).close();
    return (r.statusCode, r.headers.contentType?.mimeType, await r.transform(utf8.decoder).join());
  }

  final (code, type, content) = await task('GET', '/v9/nie-ma');
  check('nieznana ścieżka /v9/... → 404 JSON bez bazy',
      code == 404 && type == 'application/json' && jsonDecode(content)['error'] == 'not found');
  // bez Redisa i bazy rozpoznanie tenanta pada — klient API dostaje 500 w JSON
  final (k5, t5, b5) = await task('POST', '/v9/zdarzenia');
  check('awaria strony api → 500 JSON',
      k5 == 500 && t5 == 'application/json' && jsonDecode(b5)['error'] == 'internal server error');
  client.close(force: true);
  await server.close(force: true);
  exit(0); // pula Postgresa (gdy jest baza) trzyma proces
}
