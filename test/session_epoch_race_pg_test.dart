// HARD-L.13.7: a panel session carries the epoch read together with the password hash, and the 2FA half-session the
// epoch of its password step. "Sign out everywhere" / a password change committed while bcrypt runs (or while the code
// is being typed) leaves the new session with the old epoch, which the panel rejects.
// Run: tool/pg_test.sh test/session_epoch_race_pg_test.dart
import 'dart:convert';
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

late HttpServer server;
final client = HttpClient();
const csrf = 'testcsrf';

Future<(String, String?)> post(Map<String, String> fields) async {
  final z = await client.post('127.0.0.1', server.port, '/admin/login');
  z.headers
    ..host = 'localhost'
    ..contentType = ContentType('application', 'x-www-form-urlencoded')
    ..set('cookie', '${Engine.csrfCookie}=$csrf');
  z.followRedirects = false;
  z.write(Uri(queryParameters: {...fields, 'csrf': csrf}).query);
  final r = await z.close();
  return (await r.transform(utf8.decoder).join(), r.cookies.where((c) => c.name == Sessions.cookieName).firstOrNull?.value);
}

/// Whether the panel accepts [token] (the same comparison as AdminPage.isAbleToSee).
Future<bool> valid(String? token) async {
  final s = await Sessions.get(token);
  if (s == null) return false;
  final a = await Db.asSystem(() => Db.account(s.username));
  return a != null && a.$4 == s.epoch;
}

Future<void> signOutEverywhere(String login) => Db.inContext(0, () => Sessions.destroyAll(login));

Future<void> main() async {
  if (skipDestructive()) return;
  EntityRegistry.build();
  PageRegistry.build();
  await Schema.sync();
  const plain = 'eprace', withCode = 'eprace2fa', password = 'Haslo-testowe-123';
  final secret = Totp.newSecret();
  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute("DELETE FROM users WHERE username IN ('eprace', 'eprace2fa')");
    for (final u in [plain, withCode]) {
      await c.execute(Sql.named("INSERT INTO users (username, pass_hash, realm, service) VALUES (@u, @h, 'staff', 0)"),
          parameters: {'u': u, 'h': BCrypt.hashpw(password, BCrypt.gensalt(logRounds: Db.bcryptCost))});
      await c.execute(Sql.named("INSERT INTO user_packages (username, package_id) VALUES (@u, 'root')"), parameters: {'u': u});
    }
    await c.execute("INSERT INTO packages (id, name, description, service) VALUES ('root', 'Root', '', 0) ON CONFLICT DO NOTHING");
    await c.execute("INSERT INTO package_permissions (package_id, permission) VALUES ('root', '*') ON CONFLICT DO NOTHING");
    await Permissions.setTotp(withCode, secret);
  });
  Future<void> clearLimits() => Redis.cmd(['FLUSHDB']);
  await clearLimits();
  server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () => dispatch(req, const [])));

  final (_, s0) = await post({'username': plain, 'password': password});
  check('plain sign-in gives a valid session', await valid(s0));

  // (a) the only bcrypt worker is busy: the sign-in has read the hash and waits; meanwhile "sign out everywhere" commits
  Db.bcryptWorkers = 1;
  final busy = Db.bcrypt(() => sleep(const Duration(seconds: 2)));
  final login = post({'username': plain, 'password': password});
  await Future<void>.delayed(const Duration(milliseconds: 700));
  await signOutEverywhere(plain);
  await busy;
  final (_, s1) = await login;
  Db.bcryptWorkers = Platform.numberOfProcessors;
  check('the racing sign-in got a cookie', s1 != null);
  check('…but its session carries the epoch from before "sign out everywhere" and is rejected', !await valid(s1));
  check('the earlier session is gone as well', !await valid(s0));

  // (b) 2FA: password step, then "sign out everywhere", then the right code
  await clearLimits();
  final (h2, _) = await post({'username': withCode, 'password': password});
  final half = RegExp(r'name="step2" value="([0-9a-f]{48})"').firstMatch(h2)!.group(1)!;
  await signOutEverywhere(withCode);
  final (b2, s2) = await post({'step2': half, 'code': Totp.code(secret)!});
  check('a half-session from before "sign out everywhere" gets no session cookie at all', s2 == null);
  check('…and is told the sign-in expired', b2.contains(I18n.t('en', 'ignis.msg.login.expired')));

  await clearLimits();
  final (h3, _) = await post({'username': withCode, 'password': password});
  final half3 = RegExp(r'name="step2" value="([0-9a-f]{48})"').firstMatch(h3)!.group(1)!;
  final (_, s3) = await post({'step2': half3, 'code': Totp.code(secret, now: DateTime.now().add(const Duration(seconds: 30)))!});
  check('a fresh half-session with the right code still signs in', await valid(s3));

  // (c) rolling restart: a half-session written by a 0.2.0 node holds just the login; the epoch comes from the database
  await clearLimits();
  const old = '0123456789abcdef0123456789abcdef0123456789abcdef';
  await Redis.setEx('2fa:${Sessions.hashToken(old)}', withCode, 300);
  final current = (await Db.asSystem(() => Db.account(withCode)))!.$4;
  check('a 0.2.0 half-session (plain login) is accepted with the epoch from the database',
      await Db.asSystem(() => Sessions.awaiting(old)) == (withCode, current));
  final (_, s4) = await post({'step2': old, 'code': Totp.code(secret, now: DateTime.now().add(const Duration(seconds: 30)))!});
  check('…and the right code signs in', await valid(s4));

  client.close(force: true);
  await server.close(force: true);
  print('\nALL PASSED');
  exit(0);
}
