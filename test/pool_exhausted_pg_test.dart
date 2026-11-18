// HARD-L.3: a request that cannot get a pool connection in time gets 503 with Retry-After (Overloaded),
// not 500. Pool = 1, one request holds the connection.
// Run: tool/pg_test.sh test/pool_exhausted_pg_test.dart
import 'dart:async';
import 'dart:io';

import 'package:ignis/ignis.dart';
// ignore: unused_import
import 'package:ignis/entities.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

final _hold = Completer<void>(), _holding = Completer<void>();

@Page('/test-hold', technical: true)
class HoldPage extends PageEngine {
  @override
  Future<bool> doBeforeProcess() async {
    await (await Db.connect()).execute('SELECT 1');
    _holding.complete();
    await _hold.future;
    return respond(200, {'ok': true});
  }
}

@Page('/test-query', technical: true)
class QueryPage extends PageEngine {
  @override
  Future<bool> doBeforeProcess() async {
    await (await Db.connect()).execute('SELECT 1');
    return respond(200, {'ok': true});
  }
}

Future<void> main() async {
  if (Platform.environment['IGNIS_DB_HOST'] == null) {
    print('  skipped — no IGNIS_DB_HOST (tool/pg_test.sh)');
    return;
  }
  if (Platform.environment['IGNIS_DB_POOL'] != '1') {
    final r = await Process.run(Platform.resolvedExecutable, ['run', Platform.script.toFilePath()],
        environment: {'IGNIS_DB_POOL': '1'});
    stdout.write(r.stdout);
    stderr.write(r.stderr);
    exit(r.exitCode);
  }
  EntityRegistry.build();
  PageRegistry.build();
  await Schema.sync();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () => dispatch(req, const [])));
  final client = HttpClient();
  Future<HttpClientResponse> get(String s) async {
    final z = await client.get('127.0.0.1', server.port, s);
    z.headers.host = 'localhost';
    return z.close();
  }

  final held = get('/test-hold');
  await _holding.future;
  final r = await get('/test-query');
  await r.drain<void>();
  check('pool exhausted → 503 (got ${r.statusCode})', r.statusCode == 503);
  check('…with Retry-After', r.headers.value(HttpHeaders.retryAfterHeader) != null);
  _hold.complete();
  final h = await held;
  await h.drain<void>();
  check('the holding request finishes with 200', h.statusCode == 200);
  final again = await get('/test-query');
  await again.drain<void>();
  check('with the connection back the next request gets 200', again.statusCode == 200);

  client.close(force: true);
  await server.close(force: true);
  print('\nALL PASSED');
  exit(0);
}
