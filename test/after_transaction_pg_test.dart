// FIX-17: zrzut cache uprawnień i koniec sesji konta dopiero PO końcu transakcji żądania (Db.poTransakcji),
// nie przed COMMIT — równoległe żądanie nie odbuduje cache ze starych danych, stare hasło nie zostawi sesji.
// Uruchomienie: tool/pg_test.sh test/after_transaction_pg_test.dart
import 'dart:io';

import 'package:ignis/engine/db.dart';
import 'package:ignis/engine/orm.dart';
import 'package:ignis/engine/permissions.dart';
import 'package:ignis/engine/redis.dart';
import 'package:ignis/engine/schema.dart';
import 'package:ignis/engine/session.dart';
// ignore: unused_import
import 'package:ignis/entities.dart';
import 'pg_guard.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  if (skipDestructive()) return;
  EntityRegistry.build();
  await Schema.sync();
  Future<bool> sessionAlive(String t) async => await Sessions.get(t) != null;

  final t1 = await Sessions.create('ptx');
  await Redis.setEx('perm:ptx', '{}', 60);
  late bool sessionInProgress, cacheInProgress;
  await Db.inContext(0, () async {
    await (await Db.connect()).execute("UPDATE users SET must_change_password = must_change_password WHERE username = 'ptx'");
    await Sessions.destroyAll('ptx');
    await Permissions.invalidate('ptx');
    sessionInProgress = await sessionAlive(t1);
    cacheInProgress = await Redis.get('perm:ptx') != null;
  });
  check('w otwartej transakcji sesja i cache jeszcze są (zapis niezatwierdzony)', sessionInProgress && cacheInProgress);
  check('po COMMIT sesja zamknięta i cache zrzucony', !await sessionAlive(t1) && await Redis.get('perm:ptx') == null);

  final t2 = await Sessions.create('ptx');
  try {
    await Db.inContext(0, () async {
      await (await Db.connect()).execute('SELECT 1');
      await Sessions.destroyAll('ptx');
      throw StateError('błąd żądania');
    });
  } on StateError catch (_) {}
  check('po ROLLBACK też (np. zamknięcie sesji po zbyt wielu złych hasłach)', !await sessionAlive(t2));

  final t3 = await Sessions.create('ptx');
  String? t3b;
  await Db.inContext(0, () async {
    await Sessions.destroyAll('ptx'); // podbicie epoki otwiera transakcję — sprzątanie po niej
    t3b = await Sessions.create('ptx'); // nowa sesja w tym samym żądaniu (np. po włączeniu 2FA)
  });
  check('sprzątanie po transakcji nie zabiera sesji założonej po destroyAll', !await sessionAlive(t3) && await sessionAlive(t3b!));
  final t4 = await Sessions.create('ptx');
  await Permissions.invalidate('ptx');
  await Redis.setEx('perm:ptx', '{}', 60);
  await Permissions.invalidate('ptx');
  check('bez otwartej transakcji — od razu', await Redis.get('perm:ptx') == null && await sessionAlive(t4));
  await Db.close();
  print('\nALL PASSED');
  exit(0);
}
