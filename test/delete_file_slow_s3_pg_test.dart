// IGNIS-054.8: Storage.deleteFile does not hold a pool connection while S3 deletes the object, and the delete has
// the transfer deadline — a storage that accepts and never answers held a connection forever (pool of 1 = every
// other request waiting). The order and the error stay: object first, the row only after it; an S3 error (here the
// timeout) leaves the row and goes to the caller.
// The parent runs a "storage" that accepts TCP and never answers, and re-runs this file as a child with
// IGNIS_DB_POOL=1 and IGNIS_S3_* pointed at it (like delete_file_pg_test, Storage reads the environment).
// Run: tool/pg_test.sh test/delete_file_slow_s3_pg_test.dart
import 'dart:async';
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
  if (skipDestructive()) return;
  if (Platform.environment['IGNIS_S3_HOST'] == null) {
    final held = <Socket>[];
    final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    silent.listen((s) {
      held.add(s);
      s.listen((_) {}, onError: (_) {}); // read, never answer
    });
    final r = await Process.run(Platform.resolvedExecutable, ['run', Platform.script.toFilePath()], environment: {
      'IGNIS_DB_POOL': '1',
      'IGNIS_S3_HOST': '127.0.0.1', 'IGNIS_S3_PORT': '${silent.port}', 'IGNIS_S3_KEY': 'x', 'IGNIS_S3_SECRET': 'xxxxxxxx'});
    for (final s in held) {
      s.destroy();
    }
    await silent.close();
    stdout.write(r.stdout);
    stderr.write(r.stderr);
    exit(r.exitCode);
  }
  EntityRegistry.build(ignisRegistry);
  await Schema.sync();
  Storage.transferDeadline = const Duration(seconds: 3);
  final id = await Db.asSystem(() async => (await (await Db.connect()).execute(Sql.named(
          '''INSERT INTO files (key, name, path, type, size, hash, uploaded_by, uploaded_at, description, service)
             VALUES (@k, 'a.txt', '/', 'text/plain', 1, 'x', 'test', now()::text, '', 0) RETURNING id'''),
      parameters: {'k': 't0/2026/11/${'1' * 32}.txt'})).first[0] as int);

  Object? error;
  final sw = Stopwatch()..start();
  final deleting = Db.asSystem(() => Storage.deleteFile(id, 0)).catchError((Object e) => error = e);
  await Future.delayed(const Duration(milliseconds: 500));
  Object? other;
  try {
    other = await Db.asSystem(() async => (await (await Db.connect()).execute('SELECT 41 + 1')).first[0])
        .timeout(const Duration(seconds: 2));
  } on TimeoutException {
    other = 'pool blocked';
  }
  check('pool of 1: another query runs while S3 hangs ($other)', other == 42);
  await deleting.timeout(const Duration(seconds: 20), onTimeout: () => error = 'no deadline');
  check('the hanging delete ends at the transfer deadline (${sw.elapsed}, $error)', error is TimeoutException);
  final present = await Db.asSystem(() async =>
      (await (await Db.connect()).execute(Sql.named('SELECT 1 FROM files WHERE id=@i'), parameters: {'i': id})).isNotEmpty);
  check('the row stays after the S3 error', present);
  await Db.asSystem(() async =>
      (await Db.connect()).execute(Sql.named('DELETE FROM files WHERE id=@i'), parameters: {'i': id}));
  print('\nALL PASSED');
  exit(0);
}
