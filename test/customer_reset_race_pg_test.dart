// HARD-L.13.6: a password-reset token is consumed atomically (GET+DEL in one Redis script): of parallel resets with
// the same token exactly one sets the password. A database error after the consumption leaves the token used.
// A mistyped (too short) password does not use the token up.
// Run: tool/pg_test.sh test/customer_reset_race_pg_test.dart
import 'dart:io';

import 'package:ignis/engine/customer_accounts.dart';
import 'package:ignis/engine/db.dart';
import 'package:ignis/engine/orm.dart';
import 'package:ignis/engine/redis.dart';
import 'package:ignis/engine/schema.dart';
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
  const email = 'reset-race@x.pl';
  await Db.inContext(1, () => CustomerAccounts.setPassword(1, email, 'Haslo-klienta-0'));

  for (final n in [2, 16]) {
    await Redis.cmd(['EVAL', "for _,k in ipairs(redis.call('KEYS','rl:reset:*')) do redis.call('DEL',k) end", '0']);
    final token = (await Db.inContext(1, () => CustomerAccounts.resetToken(1, email)))!;
    check('$n×: a too short password does not use the token up',
        await Db.inContext(1, () => CustomerAccounts.resetPassword(1, token, 'short')) != CustomerAccounts.resetMessage &&
            await Redis.get(CustomerAccounts.resetKey(token)) != null);
    final results = await Future.wait([
      for (var i = 0; i < n; i++) Db.inContext(1, () => CustomerAccounts.resetPassword(1, token, 'Haslo-nowe-$n-$i')),
    ]);
    check('$n parallel resets with one token → exactly one succeeds (${results.where((r) => r == '').length})',
        results.where((r) => r == '').length == 1 &&
            results.where((r) => r == CustomerAccounts.resetMessage).length == n - 1);
  }

  // the password changes (committed) after the reset started but before the token is consumed: Redis writes are paused,
  // so the consuming script waits; the fingerprint must be checked on what the script returned, after it
  await Redis.cmd(['EVAL', "for _,k in ipairs(redis.call('KEYS','rl:reset:*')) do redis.call('DEL',k) end", '0']);
  final late = (await Db.inContext(1, () => CustomerAccounts.resetToken(1, email)))!;
  final other = Db.hashPassword('Haslo-zmienione-1');
  await Process.run('redis-cli', ['-p', Platform.environment['IGNIS_REDIS_PORT'] ?? '6379', 'CLIENT', 'PAUSE', '1500', 'WRITE']);
  final pending = Db.inContext(1, () => CustomerAccounts.resetPassword(1, late, 'Haslo-spoznione-1'));
  await Future<void>.delayed(const Duration(milliseconds: 500));
  await Db.asSystem(() async => (await Db.connect()).execute(
      Sql.named("UPDATE users SET pass_hash=@h WHERE username=@u"),
      parameters: {'h': other, 'u': CustomerAccounts.accountLogin(1, email)}));
  check('a password changed before the token was consumed rejects the reset',
      await pending == CustomerAccounts.resetMessage);
  check('…and the changed password stays',
      (await Db.inContext(1, () => CustomerAccounts.loginWithPassword(1, email, 'Haslo-zmienione-1'))).$1 != null);

  await Redis.cmd(['EVAL', "for _,k in ipairs(redis.call('KEYS','rl:reset:*')) do redis.call('DEL',k) end", '0']);
  final token = (await Db.inContext(1, () => CustomerAccounts.resetToken(1, email)))!;
  var failed = false;
  try {
    await Db.inContext(1, () async {
      await CustomerAccounts.resetPassword(1, token, 'Haslo-po-bledzie-1');
      throw StateError('database error after the reset');
    });
  } on StateError {
    failed = true;
  }
  check('the request failed after the reset', failed);
  check('…the password change was rolled back',
      (await Db.inContext(1, () => CustomerAccounts.loginWithPassword(1, email, 'Haslo-po-bledzie-1'))).$1 == null);
  check('…and the token stays used', await Redis.get(CustomerAccounts.resetKey(token)) == null &&
      await Db.inContext(1, () => CustomerAccounts.resetPassword(1, token, 'Haslo-po-bledzie-2')) ==
          CustomerAccounts.resetMessage);
  await Db.close();
  print('\nALL PASSED');
  exit(0);
}
