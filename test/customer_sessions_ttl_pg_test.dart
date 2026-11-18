// PERF-A-3: zbiór sesji konta klienta (csessuser:) ma TTL — nie rośnie bez końca po wygasłych sesjach.
// Uruchomienie: tool/pg_test.sh test/customer_sessions_ttl_pg_test.dart
import 'dart:io';

import 'package:ignis/engine/db.dart';
import 'package:ignis/engine/customer_accounts.dart';
import 'package:ignis/engine/orm.dart';
import 'package:ignis/engine/redis.dart';
import 'package:ignis/engine/schema.dart';
// ignore: unused_import
import 'package:ignis/entities.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  if (Platform.environment['IGNIS_DB_HOST'] == null) {
    print('  pominięte — brak IGNIS_DB_HOST (tool/pg_test.sh)');
    return;
  }
  EntityRegistry.build();
  await Schema.sync();
  const email = 'ttl@x.pl';
  final (token, _) = await Db.inContext(1, () async {
    check('konto założone', await CustomerAccounts.setPassword(1, email, 'Haslo-klienta-1') == null);
    return CustomerAccounts.loginWithPassword(1, email, 'Haslo-klienta-1');
  });
  final ttl = await Redis.cmd(['TTL', 'csessuser:1|$email']) as int;
  check('zalogowany', token != null);
  check('csessuser: ma TTL (> 0)', ttl > 0);
  await CustomerAccounts.logout(token);
  print('\nALL PASSED');
  exit(0);
}
