// IGNIS-053.5: Permissions.changePassword (admin, without `all`) of an account from another service does nothing —
// the UPDATE was scoped to the service, but Sessions.destroyAll still signed the foreign account out everywhere.
// Run: tool/pg_test.sh test/change_password_foreign_pg_test.dart
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
  await Schema.sync();
  const login = 'foreign053';
  final hash = BCrypt.hashpw('Haslo-testowe-123', BCrypt.gensalt(logRounds: 4));
  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute(Sql.named('DELETE FROM users WHERE username=@u'), parameters: {'u': login});
    await c.execute(Sql.named("INSERT INTO users (username, pass_hash, realm, service) VALUES (@u, @h, 'staff', 8)"),
        parameters: {'u': login, 'h': hash});
  });
  Future<(String, int)> row() => Db.asSystem(() async {
        final r = await (await Db.connect()).execute(
            Sql.named('SELECT pass_hash, session_epoch FROM users WHERE username=@u'), parameters: {'u': login});
        return (r.first[0] as String, r.first[1] as int);
      });
  final (_, epoch) = await row();
  final token = await Sessions.create(login, epoch: epoch);

  await Db.inContext(7, () => Permissions.changePassword(login, 'Nowe-haslo-12345', 7));
  final (hashAfter, epochAfter) = await row();
  check('service 7 does not change the password of a service-8 account', hashAfter == hash);
  check('…and does not end its sessions (epoch unchanged)', epochAfter == epoch);
  check('…and its session token is still there', (await Sessions.get(token))?.username == login);

  await Db.inContext(8, () => Permissions.changePassword(login, 'Nowe-haslo-12345', 8));
  final (ownHash, ownEpoch) = await row();
  check('own service: password changed and sessions ended', ownHash != hash && ownEpoch == epoch + 1);

  await Db.asSystem(() async => (await Db.connect())
      .execute(Sql.named('DELETE FROM users WHERE username=@u'), parameters: {'u': login}));
  print('\nALL PASSED');
  exit(0);
}
