// FIX-1: zmiana i usunięcie pakietu sprawdza OBECNĄ zawartość i posiadaczy, nie tylko nową listę —
// „junior" z permissions.edit nie wyczyści `root`, nie usunie pakietu wyżej postawionego konta,
// a nazwa „root…" / „…-u<N>" nie zajmie identyfikatora pakietu systemowego.
// Uruchomienie: tool/pg_test.sh test/packages_hierarchy_pg_test.dart
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
late String session;

Future<String> post(Map<String, String> fields) async {
  final z = await client.post('127.0.0.1', server.port, '/admin/permissions');
  z.headers
    ..host = 'localhost'
    ..contentType = ContentType('application', 'x-www-form-urlencoded')
    ..set('cookie', '${Engine.csrfCookie}=$csrf; ${Sessions.cookieName}=$session');
  z.followRedirects = false;
  z.write(Uri(queryParameters: {...fields, 'csrf': csrf}).query);
  final r = await z.close();
  await r.drain<void>();
  return r.headers.value('location') ?? '';
}

Future<String> contents(String id) async => Db.asSystem(() async => [
      for (final r in await (await Db.connect()).execute(
          Sql.named('SELECT permission FROM package_permissions WHERE package_id=@i ORDER BY 1'),
          parameters: {'i': id}))
        r[0] as String
    ].join(','));

Future<bool> present(String id) async => Db.asSystem(() async =>
    (await (await Db.connect()).execute(Sql.named('SELECT 1 FROM packages WHERE id=@i'), parameters: {'i': id}))
        .isNotEmpty);

Future<void> main() async {
  if (Platform.environment['IGNIS_DB_HOST'] == null) {
    print('  pominięte — brak IGNIS_DB_HOST (tool/pg_test.sh)');
    return;
  }
  EntityRegistry.build();
  PageRegistry.build();
  await Schema.sync();
  const packages = {
    'root': ['*'],
    'hjunior': ['dashboard.view', 'permissions.edit', 'permissions.view'],
    'hwysoki': ['*'],
    'hniski': ['dashboard.view'],
    'hwolny': ['dashboard.view'],
  };
  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute("DELETE FROM user_packages WHERE username IN ('hjunior', 'hszef')");
    await c.execute("DELETE FROM users WHERE username IN ('hjunior', 'hszef')");
    await c.execute("DELETE FROM package_permissions WHERE package_id LIKE 'h%' OR package_id LIKE 'p-root%' OR package_id = 'root'");
    await c.execute("DELETE FROM packages WHERE id LIKE 'h%' OR id LIKE 'p-root%'");
    for (final k in ['dashboard.view', 'permissions.view', 'permissions.edit', 'settings.edit']) {
      await c.execute(Sql.named('INSERT INTO permissions (key) VALUES (@k) ON CONFLICT DO NOTHING'),
          parameters: {'k': k});
    }
    for (final e in packages.entries) {
      await c.execute(Sql.named("INSERT INTO packages (id, name, service) VALUES (@i, @i, 0) ON CONFLICT DO NOTHING"),
          parameters: {'i': e.key});
      for (final p in e.value) {
        await c.execute(Sql.named('INSERT INTO package_permissions (package_id, permission) VALUES (@i, @p)'),
            parameters: {'i': e.key, 'p': p});
      }
    }
    for (final (u, p) in [('hjunior', ['hjunior']), ('hszef', ['root', 'hniski'])]) {
      await c.execute(Sql.named("INSERT INTO users (username, pass_hash, realm, service) VALUES (@u, @h, 'staff', 0)"),
          parameters: {'u': u, 'h': BCrypt.hashpw('Haslo-testowe-123', BCrypt.gensalt(logRounds: 4))});
      for (final x in p) {
        await c.execute(Sql.named('INSERT INTO user_packages (username, package_id) VALUES (@u, @p)'),
            parameters: {'u': u, 'p': x});
      }
    }
  });
  await Permissions.invalidate();
  session = await Sessions.create('hjunior');
  server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () => dispatch(req, const [])));

  var l = await post({'triggerAction': 'package_save', 'id': 'root', 'name': 'Root'});
  check('junior nie wyczyści root (pusta lista)', l.contains('flash_type=danger') && await contents('root') == '*');
  l = await post({'triggerAction': 'package_delete', 'id': 'hwysoki'});
  check('junior nie usunie pakietu z treścią ponad siebie', l.contains('flash_type=danger') && await present('hwysoki'));
  l = await post({'triggerAction': 'package_save', 'id': 'hwysoki', 'name': 'x'});
  check('…ani go nie wyczyści', l.contains('flash_type=danger') && await contents('hwysoki') == '*');
  l = await post({'triggerAction': 'package_delete', 'id': 'hniski'});
  check('junior nie usunie pakietu, który ma konto wyżej', l.contains('flash_type=danger') && await present('hniski'));
  l = await post({'triggerAction': 'package_save', 'id': 'hwolny', 'name': 'wolny', 'perm_dashboard.view': 'on', 'perm_permissions.view': 'on'});
  check('pakiet bez posiadaczy w swoim zakresie — zapis działa',
      l.contains('flash_type=success') && await contents('hwolny') == 'dashboard.view,permissions.view');
  l = await post({'triggerAction': 'package_delete', 'id': 'hjunior'});
  check('usunięcie własnego pakietu z permissions.edit — odmowa', l.contains('flash_type=danger') && await present('hjunior'));
  l = await post({'triggerAction': 'package_delete', 'id': 'hwolny'});
  check('…a zwykłego — działa', l.contains('flash_type=success') && !await present('hwolny'));

  await post({'triggerAction': 'package_add', 'name': 'Root'});
  await post({'triggerAction': 'package_add', 'name': 'root u7'});
  check('nazwa „Root” nie zajmuje id systemowego (p-root, p-root-u7-p)',
      await present('p-root') && await present('p-root-u7-p') && !await present('root-u7'));
  check('pakietSystemowy: root i root-u<N>, nie root-uX',
      Permissions.systemPackage('root') && Permissions.systemPackage('root-u12') &&
          !Permissions.systemPackage('root-ux') && !Permissions.systemPackage('p-root'));

  await Sessions.destroyAll('hjunior');
  client.close(force: true);
  await server.close(force: true);
  print('\nALL PASSED');
  exit(0);
}
