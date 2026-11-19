// FIX-9: strona plików ze stronicowaniem, lista folderów raz na stronę (nie w każdym wierszu), podfoldery po
// `rodzic` (`_` w nazwie nie jest wieloznacznikiem), przeniesienie tylko do istniejącego folderu.
// Uruchomienie: tool/pg_test.sh test/files_list_pg_test.dart
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

Future<void> main() async {
  if (skipDestructive()) return;
  EntityRegistry.build(ignisRegistry);
  PageRegistry.build(ignisRegistry);
  await Schema.sync();
  late int file;
  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute("DELETE FROM files WHERE service = 0 AND uploaded_by = 'pltest'");
    await c.execute("DELETE FROM folders WHERE service = 0 AND created_by = 'pltest'");
    await c.execute("DELETE FROM user_packages WHERE username = 'pltest'");
    await c.execute("DELETE FROM users WHERE username = 'pltest'");
    await c.execute(Sql.named("INSERT INTO users (username, pass_hash, realm, service) VALUES ('pltest', @h, 'staff', 0)"),
        parameters: {'h': BCrypt.hashpw('Haslo-testowe-123', BCrypt.gensalt(logRounds: 4))});
    await c.execute("INSERT INTO packages (id, name, description, service) VALUES ('root', 'Root', '', 0) ON CONFLICT DO NOTHING");
    await c.execute("INSERT INTO package_permissions (package_id, permission) VALUES ('root', '*') ON CONFLICT DO NOTHING");
    await c.execute("INSERT INTO user_packages (username, package_id) VALUES ('pltest', 'root')");
    final a = (await c.execute("INSERT INTO folders (name, path, parent, created_by, created_at, service) "
            "VALUES ('a_b', '/pl_t/', 0, 'pltest', '', 0) RETURNING id"))
        .first[0] as int;
    await c.execute(Sql.named("INSERT INTO folders (name, path, parent, created_by, created_at, service) "
        "VALUES ('dziecko', '/pl_t/dziecko/', @r, 'pltest', '', 0), ('obcy', '/plxt/obcy/', 0, 'pltest', '', 0)"), parameters: {'r': a});
    for (var i = 0; i < 60; i++) {
      final r = await c.execute(Sql.named("INSERT INTO files (key, name, path, type, size, hash, uploaded_by, uploaded_at, description, service) "
          "VALUES (@k, @n, '/pl_t/', 'text/plain', 1, '', 'pltest', @d, '', 0) RETURNING id"),
          parameters: {'k': 'pltest-$i', 'n': 'plik-$i.txt', 'd': '2026-01-01T00:00:${i.toString().padLeft(2, '0')}'});
      file = r.first[0] as int;
    }
  });
  await Permissions.invalidate('pltest');
  final session = await Sessions.create('pltest');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () => dispatch(req, const [])));
  final client = HttpClient();
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

  final html = await task('GET', '/admin/files?f=${Uri.encodeComponent('/pl_t/')}');
  check('strona 1: 50 z 60 plików, najnowszy pierwszy',
      'name="triggerAction" value="file_delete"'.allMatches(html).length == 50 && html.contains('plik-59.txt') && !html.contains('plik-9.txt<'));
  check('lista folderów jeden raz (datalist), nie w każdym wierszu',
      'id="folder-paths"'.allMatches(html).length == 1 && 'value="/plxt/obcy/"'.allMatches(html).length == 1);
  check('pager', html.contains('51–60') || html.contains('1–50'));
  final html2 = await task('GET', '/admin/files?f=${Uri.encodeComponent('/pl_t/')}&page=2');
  check('strona 2: pozostałe 10', 'name="triggerAction" value="file_delete"'.allMatches(html2).length == 10);

  final under = await Db.asSystem(() => Storage.subfolders('/pl_t/', 0));
  check('podfoldery po rodzicu: tylko dziecko (bez /plxt/ przez `_`)',
      under.length == 1 && under.single.name == 'dziecko');

  final l = await task('POST', '/admin/files',
      {'triggerAction': 'file_save', 'f': '/pl_t/', 'id': '$file', 'name': 'plik-59.txt', 'move_to': '/nie-ma/'});
  final location = await Db.asSystem(() async =>
      (await (await Db.connect()).execute(Sql.named('SELECT path FROM files WHERE id=@i'), parameters: {'i': file})).first[0]);
  check('przeniesienie do nieistniejącego folderu — odmowa', l.contains('flash_type=danger') && location == '/pl_t/');

  await Sessions.destroyAll('pltest');
  client.close(force: true);
  await server.close(force: true);
  print('\nALL PASSED');
  exit(0);
}
