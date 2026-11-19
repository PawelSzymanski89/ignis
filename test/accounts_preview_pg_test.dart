// FIX-44: lista kont (pulpit, zakładka Konta, ?account=) tylko z users.view.
// Uruchomienie: tool/pg_test.sh test/accounts_preview_pg_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:bcrypt/bcrypt.dart';
import 'package:ignis/ignis.dart';
import 'package:postgres/postgres.dart' show Sql;
// ignore: unused_import
import 'package:ignis/entities.dart';
// ignore: unused_import
import 'package:ignis/pages.dart';
import 'package:ignis/ignis_registry.g.dart';
import 'pg_guard.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

late HttpServer server;
final client = HttpClient();

Future<(int, String)> fetch(String path, String session) async {
  final z = await client.get('127.0.0.1', server.port, path);
  z.headers
    ..host = 'localhost'
    ..set('cookie', '${Sessions.cookieName}=$session');
  z.followRedirects = false;
  final r = await z.close();
  return (r.statusCode, await r.transform(utf8.decoder).join());
}

Future<void> main() async {
  if (skipDestructive()) return;
  EntityRegistry.build(ignisRegistry);
  PageRegistry.build(ignisRegistry);
  await Schema.sync();
  const without = 'fix44bez', z = 'fix44z';
  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute("DELETE FROM users WHERE username IN ('fix44bez', 'fix44z')");
    await c.execute("DELETE FROM packages WHERE id IN ('fix44a', 'fix44b')");
    for (final (u, pkg) in [(without, 'fix44a'), (z, 'fix44b')]) {
      await c.execute(Sql.named("INSERT INTO users (username, pass_hash, realm, service) VALUES (@u, @h, 'staff', 0)"),
          parameters: {'u': u, 'h': BCrypt.hashpw('Haslo-testowe-123', BCrypt.gensalt(logRounds: 4))});
      await c.execute(Sql.named("INSERT INTO packages (id, name, description, service) VALUES (@p, @p, '', 0)"),
          parameters: {'p': pkg});
      await c.execute(Sql.named('INSERT INTO user_packages (username, package_id) VALUES (@u, @p)'),
          parameters: {'u': u, 'p': pkg});
    }
    await c.execute("INSERT INTO package_permissions (package_id, permission) VALUES "
        "('fix44a', 'dashboard.view'), ('fix44a', 'permissions.view'), "
        "('fix44b', 'dashboard.view'), ('fix44b', 'permissions.view'), ('fix44b', 'users.view')");
  });
  for (final u in [without, z]) {
    await Permissions.invalidate(u);
  }
  final sWithout = await Db.asSystem(() => Sessions.create(without));
  final sZ = await Db.asSystem(() => Sessions.create(z));
  server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () => dispatch(req, const [])));

  final (k1, p1) = await fetch('/admin', sWithout);
  check('pulpit bez users.view: bez tabeli „Kto co może” i loginów',
      k1 == 200 && !p1.contains('Who can do what') && !p1.contains(z));
  final (k2, p2) = await fetch('/admin', sZ);
  check('pulpit z users.view: tabela z loginami', k2 == 200 && p2.contains('Who can do what') && p2.contains(without));
  final (k3, p3) = await fetch('/admin/permissions', sWithout);
  check('uprawnienia bez users.view: bez zakładki Konta', k3 == 200 && !p3.contains('tab-accounts') && !p3.contains(z));
  final (k4, _) = await fetch('/admin/permissions?account=$z', sWithout);
  check('?account= bez users.view → 403', k4 == 403);
  final (k5, p5) = await fetch('/admin/permissions', sZ);
  check('z users.view: zakładka Konta jest', k5 == 200 && p5.contains('tab-accounts') && p5.contains(without));

  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute("DELETE FROM users WHERE username IN ('fix44bez', 'fix44z')");
    await c.execute("DELETE FROM packages WHERE id IN ('fix44a', 'fix44b')");
  });
  client.close(force: true);
  await server.close(force: true);
  print('\nALL PASSED');
  exit(0);
}
