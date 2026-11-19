// SEC-A-12: włączanie TOTP — sekret oczekujący po stronie serwera (przy sesji), nie z formularza;
// aktywnego składnika nie da się podmienić bez hasła; sekret krótszy niż 16 znaków base32 odrzucany.
// Uruchomienie: tool/pg_test.sh test/totp_enable_pg_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:bcrypt/bcrypt.dart';
import 'package:ignis/ignis.dart';
import 'package:postgres/postgres.dart' show Sql;
// ignore: unused_import
import 'package:ignis/entities.dart';
import 'package:ignis/ignis_registry.g.dart';
import 'pg_guard.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

late HttpServer server;
final client = HttpClient();
const csrf = 'testowycsrf';
late String session;
String newSession = '';

Future<(int, String, String)> post(Map<String, String> fields) async {
  final z = await client.post('127.0.0.1', server.port, '/admin/account');
  z.headers
    ..host = 'localhost'
    ..contentType = ContentType('application', 'x-www-form-urlencoded')
    ..set('cookie', '${Engine.csrfCookie}=$csrf; ${Sessions.cookieName}=$session');
  z.followRedirects = false;
  z.write(Uri(queryParameters: {...fields, 'csrf': csrf}).query);
  final r = await z.close();
  newSession = '';
  for (final c in r.cookies) {
    if (c.name == Sessions.cookieName) newSession = c.value;
  }
  return (r.statusCode, await r.transform(utf8.decoder).join(), r.headers.value('location') ?? '');
}

Future<String> column(String login) async => await Db.asSystem(() async => (await (await Db.connect())
        .execute(Sql.named("SELECT coalesce(totp, '') FROM users WHERE username=@u"), parameters: {'u': login}))
    .first[0] as String);

Future<void> main() async {
  if (skipDestructive()) return;
  EntityRegistry.build(ignisRegistry);
  PageRegistry.build(ignisRegistry);
  await Schema.sync();
  const login = 'totpwlacz';
  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute("DELETE FROM users WHERE username = 'totpwlacz'");
    await c.execute(Sql.named("INSERT INTO users (username, pass_hash, realm, service) VALUES (@u, @h, 'staff', 0)"),
        parameters: {'u': login, 'h': BCrypt.hashpw('Haslo-testowe-123', BCrypt.gensalt(logRounds: 4))});
    await c.execute("INSERT INTO packages (id, name, description, service) VALUES ('root', 'Root', '', 0) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name");
    await c.execute("INSERT INTO package_permissions (package_id, permission) VALUES ('root', '*') ON CONFLICT DO NOTHING");
    await c.execute("INSERT INTO user_packages (username, package_id) VALUES ('totpwlacz', 'root')");
  });
  await Permissions.invalidate(login);
  session = await Db.asSystem(() => Sessions.create(login));
  server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () => dispatch(req, const [])));

  // PERF-A-2: nazwy pakietów w cache perm: (bez dwóch zapytań na każde wejście w panel)
  final perms = await Db.asSystem(() => Permissions.forUser(login));
  check('Permissions.dla niesie nazwy pakietów', perms.packages.contains('Root'));
  check('i trzyma je w perm:', (await Redis.get('perm:$login'))!.contains('"p":'));
  final (_, page, _) = await post({'triggerAction': 'brak'});
  check('podpis pod loginem z cache (Root)', page.contains('Root'));

  // sekret podsunięty w formularzu jest ignorowany — bez totp_start nie ma czego włączać
  final planted = Totp.newSecret();
  final (k0, _, l0) = await post({'triggerAction': 'totp_enable', 'secret': planted, 'code': Totp.code(planted)!});
  check('totp_wlacz bez totp_start → odmowa, nic nie zapisane',
      k0 == 302 && l0.contains('flash_type=danger') && await column(login) == '');

  final (_, html, _) = await post({'triggerAction': 'totp_start'});
  check('sekret nie wraca w ukrytym polu formularza', !html.contains('name="sekret"'));
  final raw = await Redis.get('totp-new:${Sessions.hashToken(session)}');
  final secret = Crypto.decrypt(raw ?? '', context: 'totp-nowy|$login');
  check('oczekujący sekret w Redisie przy sesji', secret.length >= 16);
  check('FIX-51: w Redisie zaszyfrowany (enc:v2, nie base32)', raw!.startsWith('enc:v2:') && !raw.contains(secret));
  // FIX-18: włączenie wymaga hasła; po włączeniu inne sesje giną, bieżąca dostaje nowy token
  final (kb, hb, _) = await post({'triggerAction': 'totp_enable', 'code': Totp.code(secret)!});
  check('totp_wlacz bez hasła → odmowa, nic nie zapisane',
      kb == 200 && hb.contains('The password does not match') && await column(login) == '');
  final other = await Db.asSystem(() => Sessions.create(login));
  final old = session;
  final (_, _, l1) = await post(
      {'triggerAction': 'totp_enable', 'secret': planted, 'code': Totp.code(secret)!, 'password_confirm': 'Haslo-testowe-123'});
  check('włączone sekretem z serwera, nie z formularza',
      l1.contains('flash_type=success') && await Db.asSystem(() => Permissions.totpSecret(login)) == secret);
  check('po włączeniu pozostałe sesje zamknięte, bieżąca odnowiona',
      await Sessions.get(other) == null && await Sessions.get(old) == null &&
          newSession.isNotEmpty && (await Sessions.get(newSession))?.username == login);
  session = newSession;

  // FIX-18: własnego 2FA nie zdejmuje się przez panel uprawnień (omijałoby hasło)
  final z = await client.post('127.0.0.1', server.port, '/admin/permissions');
  z.headers
    ..host = 'localhost'
    ..contentType = ContentType('application', 'x-www-form-urlencoded')
    ..set('cookie', '${Engine.csrfCookie}=$csrf; ${Sessions.cookieName}=$session');
  z.followRedirects = false;
  z.write(Uri(queryParameters: {'triggerAction': 'user_totp_disable', 'user_login': login, 'csrf': csrf}).query);
  final r = await z.close();
  await r.drain<void>();
  check('user_totp_wylacz na sobie → odmowa, 2FA zostaje',
      (r.headers.value('location') ?? '').contains('flash_type=danger') && await Db.asSystem(() => Permissions.hasTotp(login)));

  // FIX-33: zajęty login → wpis „odmowa” w dzienniku; ponad 20/h — limit
  Future<String> add(String fresh) async {
    final z = await client.post('127.0.0.1', server.port, '/admin/permissions');
    z.headers
      ..host = 'localhost'
      ..contentType = ContentType('application', 'x-www-form-urlencoded')
      ..set('cookie', '${Engine.csrfCookie}=$csrf; ${Sessions.cookieName}=$session');
    z.followRedirects = false;
    z.write(Uri(queryParameters: {'triggerAction': 'user_add', 'login': fresh, 'password': 'Haslo-testowe-123', 'csrf': csrf}).query);
    final r = await z.close();
    await r.drain<void>();
    return Uri.decodeQueryComponent(r.headers.value('location') ?? '');
  }
  final rlAdd = 'rl:user_add:${Sessions.hashToken(login)}';
  await Redis.del(rlAdd);
  check('zajęty login → niedostępny', (await add(login)).contains('unavailable'));
  final result = await Db.asSystem(() async => (await (await Db.connect()).execute(Sql.named(
          "SELECT result FROM audit_log WHERE actor=@k AND action='user_add' ORDER BY id DESC LIMIT 1"),
      parameters: {'k': login})).first[0]);
  check('nieudane założenie konta w dzienniku jako odmowa', result == 'denied');
  await Redis.setEx(rlAdd, '20', 3600);
  check('ponad 20 prób/h → limit', (await add('fix33-nowe')).contains('Too many'));
  await Redis.del(rlAdd);

  // aktywny składnik: start i włącz odmawiają (podmiana tylko przez wyłącz z hasłem)
  final (_, _, l2) = await post({'triggerAction': 'totp_start'});
  check('totp_start przy aktywnym składniku → odmowa', l2.contains('flash_type=danger'));
  await Redis.setEx('totp-new:${Sessions.hashToken(session)}', Crypto.encrypt(planted, context: 'totp-nowy|$login'), 600);
  final (_, _, l3) = await post({'triggerAction': 'totp_enable', 'code': Totp.code(planted)!});
  check('totp_wlacz nie nadpisuje aktywnego sekretu',
      l3.contains('flash_type=danger') && await Db.asSystem(() => Permissions.totpSecret(login)) == secret);

  Object? error;
  try {
    await Db.asSystem(() => Permissions.setTotp(login, 'A'));
  } on ArgumentError catch (e) {
    error = e;
  }
  check('sekret krótszy niż 16 znaków base32 odrzucony', error != null);

  // SEC-A-15: potwierdzenie hasła limitowane; po ${Permissions.maksPotwierdzen} błędach sesje konta się kończą
  await Redis.del(Permissions.confirmationsKey(login));
  // FIX-36: nieudane logowania z tego samego adresu nie zużywają limitu potwierdzeń
  await Redis.setEx(Permissions.attemptsKey(login, '127.0.0.1'), '99', 300);
  final (_, _, l4) = await post({'triggerAction': 'totp_disable', 'password_confirm': 'zle'});
  await Redis.del(Permissions.attemptsKey(login, '127.0.0.1'));
  check('złe hasło przy wyłączaniu → odmowa, sesja żyje (licznik logowań bez wpływu)',
      l4.contains('flash_type=danger') && await Sessions.get(session) != null);
  for (var i = 1; i < Permissions.maxConfirmations; i++) {
    await post({'triggerAction': 'totp_disable', 'password_confirm': 'zle'});
  }
  check('po ${Permissions.maxConfirmations} błędach sesja zamknięta', await Sessions.get(session) == null);
  session = await Db.asSystem(() => Sessions.create(login));
  final (_, _, l5) = await post({'triggerAction': 'totp_disable', 'password_confirm': 'Haslo-testowe-123'});
  check('w oknie limitu nawet dobre hasło nie przechodzi (i zamyka sesję)',
      !l5.contains('flash_type=warning') && await Sessions.get(session) == null &&
          await Db.asSystem(() => Permissions.hasTotp(login)));
  await Redis.del(Permissions.confirmationsKey(login));
  session = await Db.asSystem(() => Sessions.create(login));
  final (_, _, l6) = await post({'triggerAction': 'totp_disable', 'password_confirm': 'Haslo-testowe-123'});
  check('po oknie dobre hasło wyłącza 2FA i zeruje licznik',
      l6.contains('flash_type=warning') && await Redis.get(Permissions.confirmationsKey(login)) == null);

  // FIX-30: odwołanie sesji trzyma baza (epoka), nie tylko Redis — token, którego Redis nie skasował, nie wchodzi
  session = await Db.asSystem(() => Sessions.create(login));
  final stored = await Redis.get('sess:${Sessions.hashToken(session)}');
  final (k7, _, _) = await post({'triggerAction': 'brak'});
  check('świeża sesja wchodzi', k7 == 200);
  await Db.asSystem(() => Sessions.destroyAll(login));
  await Redis.setEx('sess:${Sessions.hashToken(session)}', stored!, 600); // „Redis nie zdążył skasować”
  final (k8, _, l8) = await post({'triggerAction': 'brak'});
  check('sesja sprzed destroyAll odbita mimo tokenu w Redisie', k8 == 302 && l8.contains('/admin/login'));

  await Db.asSystem(() => Sessions.destroyAll(login));
  client.close(force: true);
  await server.close(force: true);
  print('\nALL PASSED');
  exit(0);
}
