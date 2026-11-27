// IGNIS-053.3: a staff account with an empty pass_hash never signs in. The check ran bcrypt against Db.emptyHash
// and accepted its match — and the dummy's password is public (test/customer_accounts_password_test.dart).
// Uruchomienie: tool/pg_test.sh test/staff_empty_hash_pg_test.dart
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
  EntityRegistry.build(ignisRegistry);
  await Schema.sync();
  const login = 'emptyhash053';
  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute(Sql.named('DELETE FROM users WHERE username=@u'), parameters: {'u': login});
    await c.execute(Sql.named("INSERT INTO users (username, pass_hash, realm, service) VALUES (@u, '', 'staff', 0)"),
        parameters: {'u': login});
  });
  for (final p in ['', 'x', 'nie-ma-takiego-konta']) {
    check('empty pass_hash, password "$p" → null', await Db.asSystem(() => Db.checkLoginWithEpoch(login, p)) == null);
    check('…and checkLogin too', await Db.asSystem(() => Db.checkLogin(login, p)) == null);
  }
  await Db.asSystem(() async => (await Db.connect())
      .execute(Sql.named('DELETE FROM users WHERE username=@u'), parameters: {'u': login}));
  print('\nALL PASSED');
  exit(0);
}
