// PERF-A-1: połączenie z puli wraca PRZED wysyłką odpowiedzi. Pula = 1; żądanie, które strumieniuje
// odpowiedź bez końca (wolny klient), nie blokuje kolejnego żądania korzystającego z bazy.
// Uruchomienie: tool/pg_test.sh test/pool_slow_client_pg_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ignis/ignis.dart';
import 'pg_guard.dart';
import 'registry_helper.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

final _endless = StreamController<List<int>>();

@Page('/test-strumien', technical: true)
class StreamPage extends PageEngine {
  @override
  Future<bool> doBeforeProcess() async {
    await (await Db.connect()).execute('SELECT 1');
    status = 200;
    saveStream(_endless.stream);
    return false;
  }
}

@Page('/test-baza', technical: true)
class WithDb extends PageEngine {
  @override
  Future<bool> doBeforeProcess() async =>
      respond(200, {'n': (await (await Db.connect()).execute('SELECT 41 + 1')).first[0]});
}

Future<void> main() async {
  if (skipDestructive()) return;
  if (Platform.environment['IGNIS_DB_POOL'] != '1') {
    // pula 1 musi być ustawiona przed pierwszym Db.pula() — uruchamiamy siebie ponownie
    final r = await Process.run(Platform.resolvedExecutable, ['run', Platform.script.toFilePath()],
        environment: {'IGNIS_DB_POOL': '1'});
    stdout.write(r.stdout);
    stderr.write(r.stderr);
    exit(r.exitCode);
  }
  PageRegistry.build(testRegistry(pages: [
    testPage(const Page('/test-strumien', technical: true), StreamPage.new),
    testPage(const Page('/test-baza', technical: true), WithDb.new),
  ]));
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () => dispatch(req, const [])));
  final client = HttpClient();
  Future<HttpClientResponse> get(String s) async {
    final z = await client.get('127.0.0.1', server.port, s);
    z.headers.host = 'localhost';
    return z.close();
  }

  // ponad bufor HttpResponse (8 KB), żeby nagłówki wyszły, a strumień został otwarty
  _endless.add(List.filled(64 * 1024, 0x61));
  final slow = await get('/test-strumien').timeout(const Duration(seconds: 5));
  check('strumień ruszył (200), odpowiedź nadal otwarta', slow.statusCode == 200);
  final r = await get('/test-baza').timeout(const Duration(seconds: 3));
  final t = await r.transform(utf8.decoder).join();
  check('drugie żądanie z bazą przechodzi mimo otwartego strumienia (pula 1)',
      r.statusCode == 200 && jsonDecode(t)['n'] == 42);
  check('/files i /health nie biorą połączenia (bezBazy)',
      PageRegistry.match('/files')!.meta.noDb && PageRegistry.match('/health')!.meta.noDb);
  print('\nALL PASSED');
  exit(0);
}
