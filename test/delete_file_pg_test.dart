// FIX-39: nieudane usunięcie obiektu z magazynu nie kasuje wiersza (obiekt dalej publiczny pod /files/<klucz>).
// Uruchomienie: tool/pg_test.sh test/delete_file_pg_test.dart — test sam wznawia się z nieosiągalnym S3.
import 'dart:io';

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
  final env = Platform.environment;
  if (skipDestructive()) return;
  if (env['IGNIS_S3_HOST'] == null) {
    // port 1 na loopbacku: połączenie odrzucone od razu — removeObject na pewno rzuci
    final r = await Process.run(Platform.resolvedExecutable, [Platform.script.toFilePath()], environment: {
      'IGNIS_S3_HOST': '127.0.0.1', 'IGNIS_S3_PORT': '1', 'IGNIS_S3_KEY': 'x', 'IGNIS_S3_SECRET': 'xxxxxxxx'});
    stdout.write(r.stdout);
    stderr.write(r.stderr);
    exit(r.exitCode);
  }
  EntityRegistry.build(ignisRegistry);
  await Schema.sync();
  final id = await Db.asSystem(() async => (await (await Db.connect()).execute(Sql.named(
          '''INSERT INTO files (key, name, path, type, size, hash, uploaded_by, uploaded_at, description, service)
             VALUES (@k, 'a.txt', '/', 'text/plain', 1, 'x', 'test', now()::text, '', 0) RETURNING id'''),
      parameters: {'k': 't0/2026/11/${'0' * 32}.txt'})).first[0] as int);
  Object? error;
  try {
    await Db.asSystem(() => Storage.deleteFile(id, 0));
  } catch (e) {
    error = e;
  }
  final present = await Db.asSystem(() async =>
      (await (await Db.connect()).execute(Sql.named('SELECT 1 FROM files WHERE id=@i'), parameters: {'i': id})).isNotEmpty);
  check('błąd magazynu idzie do wołającego', error != null);
  check('wiersz zostaje — plik nie znika z panelu, gdy obiekt dalej jest publiczny', present);
  await Db.asSystem(() async =>
      (await Db.connect()).execute(Sql.named('DELETE FROM files WHERE id=@i'), parameters: {'i': id}));
  print('\nALL PASSED');
  exit(0);
}
