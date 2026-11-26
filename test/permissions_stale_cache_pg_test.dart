// IGNIS-052.6: a permission read that started before a change must not put the old permissions back into the cache
// after the invalidation (DB read → invalidate → late SETEX of the old value for 15 min).
// Uruchomienie: tool/pg_test.sh test/permissions_stale_cache_pg_test.dart
import 'dart:async';
import 'dart:io';

import 'package:ignis/engine/permissions.dart';
import 'package:ignis/engine/redis.dart';
import 'package:ignis/engine/schema.dart';
// ignore: unused_import
import 'package:ignis/entities.dart';
import 'package:ignis/engine/orm.dart';
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
  await Permissions.invalidate('pstale');

  final reached = Completer<void>(), resume = Completer<void>();
  Permissions.debugBeforeCacheWrite = () {
    reached.complete();
    return resume.future;
  };
  final read = Permissions.forUser('pstale'); // DB read done, paused before the cache write
  await reached.future;
  Permissions.debugBeforeCacheWrite = null;
  await Permissions.invalidate('pstale'); // the change lands meanwhile
  resume.complete();
  await read;
  check('a read from before the invalidation does not write its stale value', await Redis.get('perm:{pstale}') == null);

  await Permissions.forUser('pstale');
  check('the next read caches normally', await Redis.get('perm:{pstale}') != null);
  await Permissions.invalidate('pstale');
  print('\nALL PASSED');
  exit(0);
}
