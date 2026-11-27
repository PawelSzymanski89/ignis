// IGNIS-053.1: saveSetting drops the settings cache (settings:N) after COMMIT — a change is visible right away,
// not after the 60 s TTL.
// Uruchomienie: tool/pg_test.sh test/settings_cache_pg_test.dart
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
  const service = 53, key = 'test.cache_probe';

  await Db.asSystem(() => Permissions.saveSetting(service, key, 'a'));
  check('settings() returns a', (await Db.asSystem(() => Permissions.settings(service)))[key] == 'a');
  check('settings() cached it', await Redis.get('settings:$service') != null);

  await Db.asSystem(() => Permissions.saveSetting(service, key, 'b'));
  check('settings() returns b right after the save', (await Db.asSystem(() => Permissions.settings(service)))[key] == 'b');

  late bool cachedBeforeCommit;
  await Db.asSystem(() async {
    await Permissions.settings(service);
    await Permissions.saveSetting(service, key, 'c');
    cachedBeforeCommit = await Redis.get('settings:$service') != null;
  });
  check('inside the transaction the cache is not dropped yet (no rebuild from uncommitted data)', cachedBeforeCommit);
  check('after COMMIT the cache entry is gone', await Redis.get('settings:$service') == null);
  check('settings() returns c', (await Db.asSystem(() => Permissions.settings(service)))[key] == 'c');

  print('\nALL PASSED');
  exit(0);
}
