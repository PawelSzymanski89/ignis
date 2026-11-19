// FIX-5: nieudane logowanie nie zapisuje wpisanego loginu (bywa hasłem), blokada trafia do dziennika raz na okno,
// a filtr autorów bierze się z kont, nie z dowolnego `kto` w dzienniku.
// Uruchomienie: tool/pg_test.sh test/login_audit_log_pg_test.dart
import 'dart:io';

import 'package:bcrypt/bcrypt.dart';
import 'package:ignis/ignis.dart';
import 'package:postgres/postgres.dart' show Sql;
// ignore: unused_import
import 'package:ignis/entities.dart';
import 'pg_guard.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  if (skipDestructive()) return;
  EntityRegistry.build();
  PageRegistry.build();
  await Schema.sync();
  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute("DELETE FROM users WHERE username = 'logdz'");
    await c.execute("DELETE FROM audit_log WHERE location = '/admin/login'");
    await c.execute(Sql.named("INSERT INTO users (username, pass_hash, realm, service) VALUES ('logdz', @h, 'staff', 0)"),
        parameters: {'h': BCrypt.hashpw('Haslo-testowe-123', BCrypt.gensalt(logRounds: 4))});
  });
  await Redis.del('rl:ip:${Sessions.hashToken('127.0.0.1')}');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () => dispatch(req, const [])));
  final client = HttpClient();
  Future<void> login(String login) async {
    final z = await client.post('127.0.0.1', server.port, '/admin/login');
    z.headers
      ..host = 'localhost'
      ..contentType = ContentType('application', 'x-www-form-urlencoded')
      ..set('cookie', '${Engine.csrfCookie}=t');
    z.write(Uri(queryParameters: {'csrf': 't', 'username': login, 'password': 'zle'}).query);
    await (await z.close()).drain<void>();
  }

  Future<String> entries() async => Db.asSystem(() async => (await (await Db.connect()).execute(
          "SELECT coalesce(string_agg(actor || ':' || action || ' ' || detail, ',' ORDER BY id), '') FROM audit_log WHERE location = '/admin/login'"))
      .first[0] as String);

  await login('MojeTajneHaslo!');
  await login('logdz');
  final w = await entries();
  check('nieznany login → (nieznany), wpisany tekst nie trafia do dziennika',
      w.startsWith('(unknown):login') && !w.contains('MojeTajneHaslo'));
  check('istniejące konto → jego login', w.contains('logdz:login'));
  for (var i = 0; i < 10; i++) {
    await login('logdz');
  }
  final locks = 'login_locked'.allMatches(await entries()).length;
  check('blokada konta zapisana raz na okno (12 prób → 1 wpis)', locks == 1);
  await Redis.del(Permissions.attemptsKey('logdz', '127.0.0.1'));
  for (var i = 0; i < 25; i++) {
    await login('x$i-smiec');
  }
  final w2 = await entries();
  check('blokada adresu też raz, a śmieciowe loginy nie trafiają do dziennika',
      'login_locked'.allMatches(w2).length == 2 && !w2.contains('-smiec'));
  final authors = await Db.asSystem(() => AuditLog.authors(0, all: true));
  check('autorzy z kont: logdz i (nieznany), bez śmieci',
      authors.contains('logdz') && authors.contains(AuditLog.unknown) && !authors.any((a) => a.contains('smiec')));

  client.close(force: true);
  await server.close(force: true);
  print('\nALL PASSED');
  exit(0);
}
