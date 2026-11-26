// IGNIS-050.8: required second factor for platform accounts (service 0), enforced in the authorization path.
// Run: tool/pg_test.sh test/platform_2fa_pg_test.dart
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
const csrf = 'testowycsrf', password = 'Haslo-testowe-123';
String newSession = '';

/// (status, body, location) of a request with [session]; POST when [fields] is given.
Future<(int, String, String)> call(String path, String session, {Map<String, String>? fields, String host = 'localhost'}) async {
  final z = fields == null
      ? await client.get('127.0.0.1', server.port, path)
      : await client.post('127.0.0.1', server.port, path);
  z.headers
    ..host = host
    ..set('cookie', '${Engine.csrfCookie}=$csrf; ${Sessions.cookieName}=$session');
  z.followRedirects = false;
  if (fields != null) {
    z.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
    z.write(Uri(queryParameters: {...fields, 'csrf': csrf}).query);
  }
  final r = await z.close();
  newSession = r.cookies.where((c) => c.name == Sessions.cookieName).firstOrNull?.value ?? '';
  return (r.statusCode, await r.transform(utf8.decoder).join(), Uri.decodeFull(r.headers.value('location') ?? ''));
}

Future<void> main() async {
  if (skipDestructive()) return;
  AdminPage.requirePlatform2fa = true;
  EntityRegistry.build(ignisRegistry);
  PageRegistry.build(ignisRegistry);
  await Schema.sync();
  late int svc;
  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute("DELETE FROM user_packages WHERE username IN ('p2fa', 'p2fachg', 'p2fat')");
    await c.execute("DELETE FROM users WHERE username IN ('p2fa', 'p2fachg', 'p2fat')");
    await c.execute("DELETE FROM services WHERE slug = 'p2fatest'");
    svc = (await c.execute("INSERT INTO services (name, slug, active) VALUES ('P2fa', 'p2fatest', true) RETURNING id"))
        .first[0] as int;
    await c.execute(Sql.named("INSERT INTO domains (domain, service) VALUES ('p2fatest.localhost', @s) ON CONFLICT DO NOTHING"),
        parameters: {'s': svc});
    await c.execute("INSERT INTO packages (id, name, description, service) VALUES ('root', 'Root', '', 0) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name");
    await c.execute("INSERT INTO package_permissions (package_id, permission) VALUES ('root', '*') ON CONFLICT DO NOTHING");
    await c.execute("DELETE FROM packages WHERE id = 'p2fa-t'");
    await c.execute(Sql.named("INSERT INTO packages (id, name, service) VALUES ('p2fa-t', 'P2faT', @s)"), parameters: {'s': svc});
    await c.execute("INSERT INTO package_permissions (package_id, permission) VALUES ('p2fa-t', 'dashboard.view')");
    final h = BCrypt.hashpw(password, BCrypt.gensalt(logRounds: 4));
    for (final (login, s, chg) in [('p2fa', 0, false), ('p2fachg', 0, true), ('p2fat', svc, false)]) {
      await c.execute(Sql.named("INSERT INTO users (username, pass_hash, realm, service, must_change_password) VALUES (@l, @h, 'staff', @s, @m)"),
          parameters: {'l': login, 'h': h, 's': s, 'm': chg});
    }
    await c.execute("INSERT INTO user_packages (username, package_id) VALUES ('p2fa', 'root'), ('p2fachg', 'root'), ('p2fat', 'p2fa-t')");
  });
  await Tenants.refresh();
  await Permissions.invalidate();
  server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () => dispatch(req, const [])));

  // fresh platform account without TOTP: restricted session
  var s = await Db.asSystem(() => Sessions.create('p2fa'));
  for (final p in ['/admin', '/admin/permissions', '/admin/settings', '/admin/files']) {
    final (k, _, l) = await call(p, s);
    check('no TOTP: GET $p → /admin/account', k == 302 && l.endsWith('/admin/account'));
  }
  final (kp, _, lp) = await call('/admin/permissions', s,
      fields: {'triggerAction': 'user_add', 'login': 'p2fanew', 'password': password});
  check('no TOTP: POST on another page → /admin/account, nothing done',
      kp == 302 && lp.endsWith('/admin/account') && (await Db.asSystem(() => Db.account('p2fanew'))) == null);
  final (ka, ha, _) = await call('/admin/account', s);
  check('no TOTP: /admin/account opens with the message', ka == 200 && ha.contains('Enable two-step sign-in (TOTP) to use the panel'));
  final (ks, _, ls) = await call('/admin/account', s, fields: {'triggerAction': 'sessions'});
  check('no TOTP: another action on /admin/account → refused',
      ks == 302 && ls.contains('flash_type=danger') && await Sessions.get(s) != null);
  final (kl, _, ll) = await call('/admin/logout', s, fields: {});
  check('no TOTP: logout works', kl == 302 && ll.endsWith('/admin/login') && await Sessions.get(s) == null);

  // must_change_password too: password first, TOTP actions refused
  final sc = await Db.asSystem(() => Sessions.create('p2fachg'));
  final (_, hc, _) = await call('/admin/account', sc);
  check('password + TOTP: password message first', hc.contains('Change your password') && !hc.contains('Enable two-step sign-in (TOTP) to use the panel'));
  final (_, _, lc) = await call('/admin/account', sc, fields: {'triggerAction': 'totp_start'});
  check('password + TOTP: totp_start refused before the password change', lc.contains('flash_type=danger'));

  // enabling TOTP inside the restricted session lifts the restriction at once
  s = await Db.asSystem(() => Sessions.create('p2fa'));
  await call('/admin/account', s, fields: {'triggerAction': 'totp_start'});
  final secret = Crypto.decrypt(await Redis.get('totp-new:${Sessions.hashToken(s)}') ?? '', context: 'totp-nowy|p2fa');
  final (_, _, le) = await call('/admin/account', s,
      fields: {'triggerAction': 'totp_enable', 'code': Totp.code(secret)!, 'password_confirm': password});
  check('totp_enable allowed in the restricted session', le.contains('flash_type=success') && newSession.isNotEmpty);
  s = newSession;
  final (kf, _, _) = await call('/admin/permissions', s);
  check('after enabling TOTP: full access in the same session', kf == 200);

  // the account cannot disable its required factor itself
  final (_, _, ld) = await call('/admin/account', s, fields: {'triggerAction': 'totp_disable', 'password_confirm': password});
  check('own totp_disable refused, factor stays',
      ld.contains('flash_type=danger') && await Db.asSystem(() => Permissions.hasTotp('p2fa')));
  final (_, ho, _) = await call('/admin/account', s);
  check('no disable form for a required factor', !ho.contains('value="totp_disable"'));

  // an account with TOTP signs in with the code → full session
  await Redis.delMany([Permissions.attemptsKey('p2fa', '127.0.0.1'), '2fa-fail:p2fa', '2fa-last:p2fa',
    'rl:ip:${Sessions.hashToken('127.0.0.1')}', 'rl:account:${Sessions.hashToken('p2fa')}']); // earlier tests' sign-ins from 127.0.0.1
  final (_, h1, _) = await call('/admin/login', '', fields: {'username': 'p2fa', 'password': password});
  final step2 = RegExp(r'name="step2" value="([0-9a-f]{48})"').firstMatch(h1)?.group(1);
  check('with TOTP: the password leads to step 2', step2 != null);
  await call('/admin/login', '', fields: {'step2': step2!, 'code': Totp.code(secret)!});
  final logged = newSession;
  check('with TOTP: code → session', logged.isNotEmpty);
  final (kg, _, _) = await call('/admin/permissions', logged);
  check('with TOTP: full access after sign-in', kg == 200);

  // disable-2fa from the console (what bin/account.dart does) brings the restriction back
  await Db.asSystem(() => Permissions.setTotp('p2fa', ''));
  final (kr, _, lr) = await call('/admin/permissions', logged);
  check('after console disable-2fa: restricted again', kr == 302 && lr.endsWith('/admin/account'));

  // a tenant account without TOTP works as before
  final st = await Db.asSystem(() => Sessions.create('p2fat'));
  final (kt, _, _) = await call('/admin', st, host: 'p2fatest.localhost');
  check('tenant account without TOTP: dashboard opens', kt == 200);

  // IGNIS_REQUIRE_PLATFORM_2FA=0: no restriction
  AdminPage.requirePlatform2fa = false;
  final (kn, _, _) = await call('/admin/permissions', logged);
  check('requirement off: platform account without TOTP gets in', kn == 200);
  // IGNIS_REQUIRE_STAFF_2FA=1: tenant staff restricted as well
  AdminPage.requireStaff2fa = true;
  final (kx, _, lx) = await call('/admin', st, host: 'p2fatest.localhost');
  check('staff requirement: tenant account without TOTP → /admin/account', kx == 302 && lx.endsWith('/admin/account'));

  for (final u in ['p2fa', 'p2fachg', 'p2fat']) {
    await Db.asSystem(() => Sessions.destroyAll(u));
  }
  client.close(force: true);
  await server.close(force: true);
  print('\nALL PASSED');
  exit(0);
}
