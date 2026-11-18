// FIX-6: transakcja żądania rusza przy pierwszym zapytaniu; bcrypt oddaje połączenie (Db.zwolnij), o ile nic
// nie zapisano; kolejka bcrypt ma limit (Przeciazenie → 503). Pula = 1, więc trzymane połączenie widać od razu.
// Uruchomienie: tool/pg_test.sh test/lazy_transaction_pg_test.dart
import 'dart:async';
import 'dart:io';

import 'package:ignis/ignis.dart';
// ignore: unused_import
import 'package:ignis/entities.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

final _stop = Completer<void>();

@Page('/test-bez-zapytan', technical: true)
class NoQueries extends PageEngine {
  @override
  Future<bool> doBeforeProcess() async {
    await _stop.future; // np. czekanie na zewnętrzne API — bez zapytania nie trzyma puli
    return respond(200, {'ok': true});
  }
}

@Page('/test-przeciazenie', technical: true)
class OverloadedPage extends PageEngine {
  @override
  Future<bool> doBeforeProcess() async => throw const Overloaded();
}

Future<Object?> q(String sql) async => (await (await Db.connect()).execute(sql)).first[0];

Future<void> main() async {
  if (Platform.environment['IGNIS_DB_HOST'] == null) {
    print('  pominięte — brak IGNIS_DB_HOST (tool/pg_test.sh)');
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
  Future<int> get(String s) async {
    final z = await client.get('127.0.0.1', server.port, s);
    z.headers.host = 'localhost';
    final r = await z.close();
    await r.drain<void>();
    return r.statusCode;
  }

  final dangling = get('/test-bez-zapytan');
  await Future<void>.delayed(const Duration(milliseconds: 200));
  check('żądanie bez zapytań nie trzyma połączenia (pula 1, drugie przechodzi)',
      await Db.inContext(1, () => q('SELECT 1')).timeout(const Duration(seconds: 3)) == 1);
  _stop.complete();
  check('…a samo kończy się 200', await dangling == 200);

  final w = Completer<void>(), passed = Completer<void>();
  final longValue = Db.inContext(1, () async {
    await q('SELECT 1');
    await Db.release();
    passed.complete();
    await w.future; // „bcrypt”
    return q("SELECT current_setting('ignis.service')");
  });
  await passed.future;
  check('Db.zwolnij po samych odczytach oddaje połączenie',
      await Db.inContext(2, () => q('SELECT 2')).timeout(const Duration(seconds: 3)) == 2);
  w.complete();
  check('…a następne zapytanie otwiera nową transakcję z tym samym kontekstem', await longValue == '1');

  const key = 'lenitest@0';
  await Db.asSystem(() => q("WITH d AS (DELETE FROM settings WHERE id = '$key' RETURNING 1) SELECT count(*) FROM d"));
  try {
    await Db.inContext(0, () async {
      await (await Db.connect()).execute("INSERT INTO settings (id, key, value, service) VALUES ('$key', 'lenitest', '', 0)");
      await Db.release();
      throw StateError('po zapisie');
    });
  } on StateError catch (_) {}
  check('po zapisie Db.zwolnij nic nie zatwierdza — wyjątek cofa całość',
      await Db.asSystem(() => q("SELECT count(*)::int FROM settings WHERE id = '$key'")) == 0);

  Db.bcryptWorkers = 1;
  Db.bcryptQueue = 0;
  final first = Db.bcrypt(() => Db.hashPassword('Haslo-testowe-123'));
  Object? error;
  try {
    await Db.bcrypt(() => 1);
  } catch (e) {
    error = e;
  }
  await first;
  check('kolejka bcrypt pełna → Przeciazenie', error is Overloaded);
  check('…po zwolnieniu miejsca bcrypt znowu działa', await Db.bcrypt(() => 7) == 7);
  check('Przeciazenie z żądania → 503', await get('/test-przeciazenie') == 503);

  client.close(force: true);
  await server.close(force: true);
  print('\nALL PASSED');
  exit(0);
}
