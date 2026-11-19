// FIX-8: panel platformy ładuje pakiety jednej usługi (domyślnie 0, `?service=`, a przy akcji — usługi pakietu/konta),
// zmiana pakietu czyści cache uprawnień tylko jego posiadaczom.
// Uruchomienie: tool/pg_test.sh test/packages_scope_pg_test.dart
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
late String session;

Future<String> task(String method, String path, [Map<String, String>? fields]) async {
  final z = await client.open(method, '127.0.0.1', server.port, path);
  z.headers
    ..host = 'localhost'
    ..set('cookie', '${Engine.csrfCookie}=t; ${Sessions.cookieName}=$session');
  z.followRedirects = false;
  if (fields != null) {
    z.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
    z.write(Uri(queryParameters: {...fields, 'csrf': 't'}).query);
  }
  final r = await z.close();
  return r.statusCode == 302 ? r.headers.value('location')! : await r.transform(utf8.decoder).join();
}

Future<void> main() async {
  if (skipDestructive()) return;
  EntityRegistry.build();
  PageRegistry.build();
  await Schema.sync();
  late int u;
  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute("DELETE FROM user_packages WHERE username IN ('zkroot', 'zkklient', 'zkobcy')");
    await c.execute("DELETE FROM users WHERE username IN ('zkroot', 'zkklient', 'zkobcy')");
    await c.execute("DELETE FROM package_permissions WHERE package_id IN ('zk-plat', 'zk-klient')");
    await c.execute("DELETE FROM packages WHERE id IN ('zk-plat', 'zk-klient')");
    await c.execute("DELETE FROM services WHERE slug = 'zakrestest'");
    u = (await c.execute("INSERT INTO services (name, slug, active) VALUES ('Zakres', 'zakrestest', true) RETURNING id"))
        .first[0] as int;
    await c.execute("INSERT INTO packages (id, name, description, service) VALUES ('root', 'Root', '', 0) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name");
    await c.execute("INSERT INTO package_permissions (package_id, permission) VALUES ('root', '*') ON CONFLICT DO NOTHING");
    await c.execute("INSERT INTO packages (id, name, service) VALUES ('zk-plat', 'ZkPlatformowy', 0)");
    await c.execute(Sql.named("INSERT INTO packages (id, name, service) VALUES ('zk-klient', 'ZkKliencki', @u)"), parameters: {'u': u});
    await c.execute("INSERT INTO package_permissions (package_id, permission) VALUES ('zk-plat', 'dashboard.view'), ('zk-klient', 'dashboard.view')");
    final h = BCrypt.hashpw('Haslo-testowe-123', BCrypt.gensalt(logRounds: 4));
    for (final (login, svc) in [('zkroot', 0), ('zkklient', u), ('zkobcy', 0)]) {
      await c.execute(Sql.named("INSERT INTO users (username, pass_hash, realm, service) VALUES (@l, @h, 'staff', @u)"),
          parameters: {'l': login, 'h': h, 'u': svc});
    }
    await c.execute("INSERT INTO user_packages (username, package_id) VALUES ('zkroot', 'root'), ('zkklient', 'zk-klient'), ('zkobcy', 'zk-plat')");
  });
  await Permissions.invalidate();
  session = await Sessions.create('zkroot');
  server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () => dispatch(req, const [])));

  final list = await task('GET', '/admin/permissions');
  check('platforma domyślnie: pakiety usługi 0, bez pakietów klientów',
      list.contains('ZkPlatformowy') && !list.contains('ZkKliencki'));
  final listU = await task('GET', '/admin/permissions?service=$u');
  check('?service=N — pakiety tej usługi', listU.contains('ZkKliencki') && !listU.contains('ZkPlatformowy'));
  final account = await task('GET', '/admin/permissions?account=zkklient');
  check('formularz konta klienta — pakiety jego usługi (zaznaczony zk-klient)',
      RegExp(r'name="pkg_zk-klient"[^>]*checked').hasMatch(account));
  final l = await task('POST', '/admin/permissions',
      {'triggerAction': 'user_save', 'user_login': 'zkklient', 'pkg_zk-klient': 'on'});
  check('zapis konta klienta z platformy zachowuje jego pakiet',
      l.contains('flash_type=success') && (await Db.asSystem(() => Permissions.userPackages('zkklient'))).contains('zk-klient'));

  await Db.asSystem(() => Permissions.forUser('zkobcy'));
  await Db.asSystem(() => Permissions.forUser('zkklient'));
  await task('POST', '/admin/permissions',
      {'triggerAction': 'package_save', 'id': 'zk-klient', 'name': 'ZkKliencki', 'perm_dashboard.view': 'on'});
  check('zmiana pakietu czyści cache posiadacza…', await Redis.get('perm:zkklient') == null);
  check('…a nie wszystkich kont', await Redis.get('perm:zkobcy') != null);

  await Sessions.destroyAll('zkroot');
  client.close(force: true);
  await server.close(force: true);
  print('\nALL PASSED');
  exit(0);
}
