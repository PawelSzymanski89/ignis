// FIX-2: akcja, która rzuciła (także po przerwaniu transakcji błędem SQL), zostawia wpis `blad` —
// zapisany w osobnej transakcji po ROLLBACK, a nie cofany razem z żądaniem.
// Uruchomienie: tool/pg_test.sh test/audit_log_error_pg_test.dart
import 'dart:io';

import 'package:bcrypt/bcrypt.dart';
import 'package:ignis/ignis.dart';
import 'package:postgres/postgres.dart' show Sql;
// ignore: unused_import
import 'package:ignis/entities.dart';
import 'pg_guard.dart';
import 'registry_helper.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

@Page('/admin/test-error', template: 'dashboard.html')
class TestError extends AdminPage {
  @Action('psuj')
  Future<bool> breakIt() async {
    await (await Db.connect()).execute('SELECT * FROM nie_ma_takiej_tabeli');
    return true;
  }

  @Action('dobrze')
  bool good() => back('/admin/test-error');
}

Future<void> main() async {
  if (skipDestructive()) return;
  final registry = testRegistry(pages: [
    testPage(const Page('/admin/test-error', template: 'dashboard.html'), TestError.new, cookieAuth: true,
        adminPage: true, actions: {
      'psuj': [(o) => (o as TestError).breakIt()],
      'dobrze': [(o) => (o as TestError).good()],
    })
  ]);
  EntityRegistry.build(registry);
  PageRegistry.build(registry);
  await Schema.sync();
  const login = 'dzblad';
  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute("DELETE FROM user_packages WHERE username = 'dzblad'");
    await c.execute("DELETE FROM users WHERE username = 'dzblad'");
    await c.execute("DELETE FROM audit_log WHERE actor = 'dzblad'");
    await c.execute(Sql.named("INSERT INTO users (username, pass_hash, realm, service) VALUES (@u, @h, 'staff', 0)"),
        parameters: {'u': login, 'h': BCrypt.hashpw('Haslo-testowe-123', BCrypt.gensalt(logRounds: 4))});
    await c.execute("INSERT INTO packages (id, name, description, service) VALUES ('root', 'Root', '', 0) ON CONFLICT DO NOTHING");
    await c.execute("INSERT INTO package_permissions (package_id, permission) VALUES ('root', '*') ON CONFLICT DO NOTHING");
    await c.execute("INSERT INTO user_packages (username, package_id) VALUES ('dzblad', 'root')");
  });
  await Permissions.invalidate(login);
  final session = await Sessions.create(login);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () => dispatch(req, const [])));
  final client = HttpClient();
  Future<int> post(String action) async {
    final z = await client.post('127.0.0.1', server.port, '/admin/test-error');
    z.headers
      ..host = 'localhost'
      ..contentType = ContentType('application', 'x-www-form-urlencoded')
      ..set('cookie', '${Engine.csrfCookie}=t; ${Sessions.cookieName}=$session');
    z.followRedirects = false;
    z.write('csrf=t&triggerAction=$action');
    final r = await z.close();
    await r.drain<void>();
    return r.statusCode;
  }

  Future<String> results() async => Db.asSystem(() async => (await (await Db.connect()).execute(
          "SELECT coalesce(string_agg(action || ':' || result, ',' ORDER BY id), '') FROM audit_log WHERE actor = 'dzblad'"))
      .first[0] as String);

  check('action with an SQL error → 500', await post('psuj') == 500);
  check('…and an error entry in the audit log despite the ROLLBACK', await results() == 'psuj:error');
  check('successful action → one ok entry', await post('dobrze') == 302 && await results() == 'psuj:error,dobrze:ok');

  // the panel listing query (every column it selects must exist after the rename)
  final listed = await Db.asSystem(() => AuditLog.list(0, all: true, actor: 'dzblad'));
  check('AuditLog.list (platform) returns the entries', listed.map((e) => e.result).join(',') == 'ok,error');
  final searched = await Db.asSystem(() => AuditLog.list(0, search: 'dobrze'));
  check('AuditLog.list (service, phrase) runs', searched.every((e) => e.result == 'ok'));

  await Sessions.destroyAll(login);
  client.close(force: true);
  await server.close(force: true);
  print('\nALL PASSED');
  exit(0);
}
