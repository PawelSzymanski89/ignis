// HARD-L.13.1: a customer session carries `users.session_epoch` and is checked against the database. A password change
// bumps the epoch, so a session that survived the Redis cleanup (a lost DEL, or a sign-in with the old password
// racing the change) is rejected; the Redis cleanup runs after the transaction ends.
// Run: tool/pg_test.sh test/customer_session_epoch_pg_test.dart
import 'dart:async';
import 'dart:io';

import 'package:ignis/engine/customer_accounts.dart';
import 'package:ignis/engine/db.dart';
import 'package:ignis/engine/orm.dart';
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
  const email = 'a|epoch@x.pl', p1 = 'Haslo-klienta-1', p2 = 'Haslo-klienta-2', p3 = 'Haslo-klienta-3';
  Future<CustomerSession?> session(String? t) => Db.inContext(1, () => CustomerAccounts.session(t, 1));

  final (t1, _) = await Db.inContext(1, () async {
    await CustomerAccounts.setPassword(1, email, p1);
    return CustomerAccounts.loginWithPassword(1, email, p1);
  });
  check('signed in (an e-mail with | comes back whole)', (await session(t1))?.email == email);
  check('session also works outside a request transaction', await CustomerAccounts.session(t1, 1) != null);

  // (a) the Redis value survives the password change (a lost DEL) → the epoch rejects it
  final key = 'csess:${Sessions.hashToken(t1!)}';
  final raw = (await Redis.get(key))!;
  await Db.inContext(1, () => CustomerAccounts.setPassword(1, email, p2));
  check('password change deleted the session', await Redis.get(key) == null);
  await Redis.setEx(key, raw, 600);
  check('a session restored in Redis after the change is rejected (epoch)', await session(t1) == null);

  // (b) sign-in with the old password while the change is not yet committed
  final hold = Completer<void>(), changed = Completer<void>();
  final change = Db.inContext(1, () async {
    await CustomerAccounts.setPassword(1, email, p3);
    changed.complete();
    await hold.future;
  });
  await changed.future;
  final login = Db.inContext(1, () => CustomerAccounts.loginWithPassword(1, email, p2));
  // wait until the sign-in blocks on the row lock of the uncommitted change (or finishes)
  var done = false;
  login.whenComplete(() => done = true).ignore();
  final pool = await Db.pool();
  for (var i = 0; i < 200 && !done; i++) {
    final w = await pool.execute('SELECT count(*) FROM pg_locks WHERE NOT granted');
    if ((w.first[0] as int) > 0) break;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  hold.complete();
  await change;
  final (t2, _) = await login;
  check('the racing sign-in with the old password got a token', t2 != null);
  check('…but its session is rejected after the change commits', await session(t2) == null);

  final (t3, _) = await Db.inContext(1, () => CustomerAccounts.loginWithPassword(1, email, p3));
  check('sign-in with the new password works', await session(t3) != null);
  await CustomerAccounts.logout(t3);
  await Db.close();
  print('\nALL PASSED');
  exit(0);
}
