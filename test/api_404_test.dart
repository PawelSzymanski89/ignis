// Nieznana ścieżka pod prefiksem API przez dyspozytor node'a (obsluz z Ignis.uruchom),
import 'dart:convert';
import 'dart:io';

import 'package:ignis/ignis.dart';

import 'registry_helper.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

@Page('/v1/zdarzenia', api: true, methods: ['POST'])
class ApiTest extends PageEngine {}

@Page('/fix37/api/x', api: true, noDb: true)
class ApiUnderNeighbor extends PageEngine {}

@Page('/fix37/formularz', noDb: true)
class NeighborForm extends PageEngine {
  @override
  Future<bool> doBeforeProcess() async {
    write('ok');
    return false;
  }
}

Future<void> main() async {
  // strona nie-API potrzebuje domen systemu (Tenanci) — bez nich test uruchamia sam siebie z localhost
  if (Platform.environment['IGNIS_DOMAINS'] == null) {
    final p = await Process.start(Platform.resolvedExecutable, [Platform.script.toFilePath()],
        environment: {'IGNIS_DOMAINS': 'localhost'}, mode: ProcessStartMode.inheritStdio);
    exitCode = await p.exitCode;
    return;
  }
  PageRegistry.build(testRegistry(pages: [
    testPage(const Page('/v1/zdarzenia', api: true, methods: ['POST']), ApiTest.new),
    testPage(const Page('/fix37/api/x', api: true, noDb: true), ApiUnderNeighbor.new),
    testPage(const Page('/fix37/formularz', noDb: true), NeighborForm.new),
  ]));
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () => dispatch(req, const [])));
  final client = HttpClient();
  final task = await client.open('GET', '127.0.0.1', server.port, '/v1/nie-ma');
  task.headers.host = 'example.test';
  final r = await task.close();
  final content = await r.transform(utf8.decoder).join();
  check('GET /v1/nie-ma → 404 JSON {"error": "not found"}',
      r.statusCode == 404 &&
          r.headers.contentType?.mimeType == 'application/json' &&
          jsonDecode(content)['error'] == 'not found');
  // FIX-37: strona `api: true` pod /fix37/ nie zdejmuje CSRF z sąsiednich stron
  final p = await client.open('POST', '127.0.0.1', server.port, '/fix37/formularz');
  p.headers
    ..host = 'localhost'
    ..contentType = ContentType('application', 'x-www-form-urlencoded');
  p.write('a=1');
  final pr = await p.close();
  await pr.drain<void>();
  check('POST bez tokenu na stronę obok trasy API → 403 (CSRF)', pr.statusCode == 403);
  // FIX-38: CSRF dla każdej metody poza GET/HEAD/OPTIONS; token może przyjść w ciele PUT/DELETE
  for (final m in ['PUT', 'PATCH', 'DELETE']) {
    final without = await (await client.open(m, '127.0.0.1', server.port, '/fix37/formularz')..headers.host = 'localhost').close();
    await without.drain<void>();
    final z = await client.open(m, '127.0.0.1', server.port, '/fix37/formularz');
    z.headers
      ..host = 'localhost'
      ..contentType = ContentType('application', 'x-www-form-urlencoded')
      ..set('cookie', '${Engine.csrfCookie}=tok');
    z.write('csrf=tok');
    final zt = await z.close();
    await zt.drain<void>();
    check('$m bez tokenu → 403, z tokenem w ciele → 200', without.statusCode == 403 && zt.statusCode == 200);
  }
  client.close(force: true);
  await server.close(force: true);
}
