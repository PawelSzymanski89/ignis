// SEC-A-5: @Cached na encji z `usluga` jest odrzucany przy budowie rejestru (lustro w Redisie omija RLS);
// @Cached(ttl:) trafia do metadanych. Bez bazy.
import 'dart:io';

import 'package:ignis/engine/annotations.dart';
import 'package:ignis/engine/orm.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

@Entity('test_slownik')
@Cached(ttl: 60)
class TestDictionary {
  int? id;
  String name = '';
}

Future<void> main() async {
  final r = await Process.run(Platform.resolvedExecutable, ['run', 'test/fixtures/cached_service.dart']);
  check('@Cached na encji z service → StateError przy EntityRegistry.build',
      '${r.stdout}'.contains('ODRZUCONA') && '${r.stdout}'.contains('TestCached'));
  EntityRegistry.build();
  final m = EntityRegistry.byType(TestDictionary);
  check('@Cached bez service przechodzi, ttl w metadanych', m.cached && m.ttl == 60);
  print('\nALL PASSED');
}
