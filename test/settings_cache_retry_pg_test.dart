// IGNIS-054.3: a settings cache drop (settings:N) that fails after saveSetting is retried like the permission cache
// invalidation — before, it was only logged and the old value lived on for the cache TTL.
// Redis refuses DEL through an ACL on the default user (the throw-away redis-server of tool/pg_test.sh).
// Run: tool/pg_test.sh test/settings_cache_retry_pg_test.dart
import 'dart:io';

import 'package:ignis/ignis.dart';
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
  const service = 54, key = 'test.retry_probe';

  await Db.asSystem(() => Permissions.saveSetting(service, key, 'a'));
  await Db.asSystem(() => Permissions.settings(service));
  check('settings:$service is cached', await Redis.get('settings:$service') != null);

  await Redis.cmd(['ACL', 'SETUSER', 'default', '-del']);
  try {
    await Db.asSystem(() => Permissions.saveSetting(service, key, 'b'));
    check('while Redis refuses DEL the stale entry stays', await Redis.get('settings:$service') != null);
  } finally {
    await Redis.cmd(['ACL', 'SETUSER', 'default', '+del']);
  }

  final until = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(until) && await Redis.get('settings:$service') != null) {
    await Future.delayed(const Duration(milliseconds: 200));
  }
  check('once Redis takes DEL again, the retry drops settings:$service without a new save',
      await Redis.get('settings:$service') == null);
  check('settings() returns b', (await Db.asSystem(() => Permissions.settings(service)))[key] == 'b');

  print('\nALL PASSED');
  exit(0);
}
