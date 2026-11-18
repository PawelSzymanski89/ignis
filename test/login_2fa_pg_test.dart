// SEC-A-7: drugi składnik — limit błędów per konto ponad półtokeny, krok 1 nie zeruje licznika prób,
// przyjęty kod nie działa drugi raz (replay). Uruchomienie: tool/pg_test.sh test/login_2fa_pg_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:bcrypt/bcrypt.dart';
import 'package:ignis/ignis.dart';
import 'package:postgres/postgres.dart' show Sql;
// ignore: unused_import
import 'package:ignis/entities.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

late HttpServer server;
final client = HttpClient();
const csrf = 'testowycsrf';

Future<(int, String, String?)> post(Map<String, String> fields, {String ip = '10.0.0.1'}) async {
  final z = await client.post('127.0.0.1', server.port, '/admin/login');
  z.headers
    ..host = 'localhost'
    ..contentType = ContentType('application', 'x-www-form-urlencoded')
    ..set('cookie', '${Engine.csrfCookie}=$csrf');
  z.followRedirects = false;
  z.write(Uri(queryParameters: {...fields, 'csrf': csrf}).query);
  final r = await z.close();
  final session = r.cookies.where((c) => c.name == Sessions.cookieName).firstOrNull?.value;
  return (r.statusCode, await r.transform(utf8.decoder).join(), session);
}

String? step2(String html) => RegExp(r'name="step2" value="([0-9a-f]{48})"').firstMatch(html)?.group(1);

Future<void> main() async {
  if (Platform.environment['IGNIS_DB_HOST'] == null) {
    print('  pominięte — brak IGNIS_DB_HOST (tool/pg_test.sh)');
    return;
  }
  EntityRegistry.build();
  PageRegistry.build();
  await Schema.sync();
  const login = 'totptest', password = 'Haslo-testowe-123';
  final secret = Totp.newSecret();
  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute("DELETE FROM users WHERE username = 'totptest'");
    await c.execute(Sql.named("INSERT INTO users (username, pass_hash, realm, service) VALUES (@u, @h, 'staff', 0)"),
        parameters: {'u': login, 'h': BCrypt.hashpw(password, BCrypt.gensalt())});
    await c.execute("INSERT INTO packages (id, name, description, service) VALUES ('root', 'Root', '', 0) ON CONFLICT DO NOTHING");
    await c.execute("INSERT INTO package_permissions (package_id, permission) VALUES ('root', '*') ON CONFLICT DO NOTHING");
    await c.execute("INSERT INTO user_packages (username, package_id) VALUES ('totptest', 'root')");
    await Permissions.setTotp(login, secret);
  });
  final rl = Permissions.attemptsKey(login, '127.0.0.1'); // klient testu łączy się z 127.0.0.1, bez zaufanego proxy
  await Redis.delMany([rl, '2fa-fail:$login', '2fa-last:$login']);

  server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () => dispatch(req, const [])));

  Future<String> step1(int i) async {
    final (_, html, _) = await post({'username': login, 'password': password}, ip: '10.0.1.$i');
    return step2(html) ?? (throw StateError('brak kroku 2: ${html.length > 300 ? html.substring(0, 300) : html}'));
  }

  // krok 1 nie zeruje licznika prób loginu
  await Redis.setEx(rl, '3', 300);
  final t0 = await step1(0);
  check('krok 1 z hasłem nie zeruje rl:login', int.parse(await Redis.get(rl) ?? '0') == 4);
  await Redis.del(rl);

  // replay: kod przyjęty raz nie działa drugi raz
  final code = Totp.code(secret)!;
  final (k1, _, s1) = await post({'step2': t0, 'code': code});
  check('poprawny kod → sesja', k1 == 302 && s1 != null);
  final t1 = await step1(1);
  final (_, h2, s2) = await post({'step2': t1, 'code': code});
  check('ten sam kod drugi raz → odrzucony', s2 == null && h2.contains('The code does not match'));

  // FIX-19: dwa równoległe wysłania jednego kodu — przechodzi dokładnie jedno; równoległe
  // strzały nie przekraczają limitu konta
  await Redis.delMany(['2fa-fail:$login', '2fa-last:$login', rl]);
  final (same, tb) = (await step1(2), await step1(3));
  await Redis.del(rl);
  final codeR = Totp.code(secret)!;
  final equal = await Future.wait([post({'step2': same, 'code': codeR}), post({'step2': tb, 'code': codeR})]);
  check('równoległy replay: jedna sesja, nie dwie', equal.where((r) => r.$3 != null).length == 1);
  await Redis.delMany(['2fa-fail:$login', '2fa-last:$login', rl]);
  final rlIp = 'rl:ip:${Sessions.hashToken('127.0.0.1')}';
  final tokens = <String>[];
  for (var i = 0; i < LoginPage.maxAccountFailures + 4; i++) {
    await Redis.delMany([rl, rlIp]);
    tokens.add(await step1(30 + i));
  }
  await Redis.delMany([rl, rlIp]);
  await Future.wait([for (final t in tokens) post({'step2': t, 'code': '000000'})]);
  final sticky = (await Future.wait([for (final t in tokens) Sessions.awaitingCode(t)])).whereType<String>().length;
  check('równoległe strzały: najwyżej ${LoginPage.maxAccountFailures} sprawdzeń kodu (reszta półtokenów spalona)',
      sticky <= LoginPage.maxAccountFailures);

  // limit per konto ponad półtokeny: 10 błędów na świeżych tokenach → blokada nawet dla dobrego kodu
  await Redis.delMany(['2fa-fail:$login', '2fa-last:$login', rl]);
  for (var i = 0; i < LoginPage.maxAccountFailures; i++) {
    await Redis.del(rl);
    await post({'step2': await step1(10 + i), 'code': '000000'});
  }
  await Redis.del(rl);
  final (_, h3, s3) = await post({'step2': await step1(99), 'code': Totp.code(secret)!});
  check('po ${LoginPage.maxAccountFailures} błędach (na różnych półtokenach) dobry kod nie wpuszcza',
      s3 == null && h3.contains('Too many wrong codes for this account'));
  final entry = await Db.asSystem(() async => (await (await Db.connect())
          .execute("SELECT count(*) FROM audit_log WHERE actor = 'totptest' AND action = '2fa_locked'"))
      .first[0] as int);
  check('blokada zapisana w dzienniku', entry >= 1);

  // SEC-A-11: nieczytelny szyfrogram TOTP nie wyłącza drugiego składnika
  await Redis.delMany([rl, '2fa-fail:$login', '2fa-last:$login']);
  await Db.asSystem(() async => (await Db.connect()).execute(
      Sql.named('UPDATE users SET totp=@t WHERE username=@u'),
      parameters: {'u': login, 't': Crypto.encrypt(secret, context: 'totp|inne-konto')}));
  check('maTotp po kolumnie mimo nieczytelnego szyfrogramu', await Db.asSystem(() => Permissions.hasTotp(login)));
  final t6 = await step1(200);
  final (_, h6, s6) = await post({'step2': t6, 'code': Totp.code(secret)!});
  check('hasło nie wystarcza, kod nie do sprawdzenia → brak sesji', s6 == null && h6.contains('The code does not match'));
  await Db.asSystem(() => Permissions.setTotp(login, secret));
  await Redis.delMany([rl, '2fa-fail:$login', '2fa-last:$login']);

  // SEC-A-17: hash niższego kosztu przeliczany przy udanym logowaniu
  final hashAfter = await Db.asSystem(() async => (await (await Db.connect())
          .execute("SELECT pass_hash FROM users WHERE username = 'totptest'")).first[0] as String);
  check('po zalogowaniu hash ma koszt ${Db.bcryptCost}', !Db.weakHash(hashAfter) && BCrypt.checkpw(password, hashAfter));

  // SEC-A-9: limit hasła per (login, adres), atomowy TTL, śmieciowy login bez klucza w Redisie
  await Redis.del(rl);
  for (var i = 0; i < 5; i++) {
    await post({'username': login, 'password': 'zle-haslo'});
  }
  final (_, h4, _) = await post({'username': login, 'password': password});
  check('po 5 błędach z tego adresu nawet dobre hasło → limit', h4.contains('Too many sign-in attempts'));
  check('licznik ma TTL (INCR+EXPIRE atomowo)', (await Redis.cmd(['TTL', rl])) as int > 0);
  check('klucz to skrót pary login+adres, nie surowy login',
      !rl.contains(login) && Permissions.attemptsKey(login, '10.0.0.2') != rl);
  final multiline = 'x' * 5000;
  final (_, h5, _) = await post({'username': multiline, 'password': 'x'});
  check('login ponad ${LoginPage.maxLogin} znaków odrzucony bez klucza w Redisie',
      h5.contains('Wrong username or password') && await Redis.get(Permissions.attemptsKey(multiline, '127.0.0.1')) == null);
  await Redis.del(rl);

  // FIX-31: miękki limit konta ponad adresy — po ${KontaKlientow.progKonta} próbach w godzinę każda czeka
  final rlAccount = 'rl:account:${Sessions.hashToken(login)}';
  await Redis.setEx(rlAccount, '${CustomerAccounts.accountThreshold}', 3600);
  final sw = Stopwatch()..start();
  final (_, hAttack, _) = await post({'username': login, 'password': 'zle-haslo'});
  check('konto pod atakiem: odpowiedź opóźniona, bez blokady',
      sw.elapsed >= CustomerAccounts.accountDelay && hAttack.contains('Wrong username or password'));
  await Redis.delMany([rl, rlAccount]);

  client.close(force: true);
  await server.close(force: true);
  print('\nALL PASSED');
  exit(0);
}
