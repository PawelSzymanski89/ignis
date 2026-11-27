// IGNIS-054.9: Orm.readAll<T>() and CustomerAccounts.list(service) take an optional {int? limit, int offset = 0} —
// LIMIT/OFFSET only when limit is given, ordered by the key as before; without limit every row, as before.
// Run: tool/pg_test.sh test/paging_pg_test.dart
import 'dart:io';

import 'package:ignis/ignis.dart';
import 'package:postgres/postgres.dart' show Sql;
// ignore: unused_import
import 'package:ignis/entities.dart';
import 'pg_guard.dart';
import 'registry_helper.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

class PageRow {
  String code = '';
}

Future<void> main() async {
  if (skipDestructive()) return;
  EntityRegistry.build(testRegistry(entities: [
    testEntity(const Entity('test_paging', pk: 'code'), PageRow, PageRow.new, [
      FieldMeta('code', String, (o) => (o as PageRow).code, (o, v) => (o as PageRow).code = v as String,
          defaultValue: ''),
    ])
  ]));
  await Schema.sync();
  const service = 954;
  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute('DELETE FROM test_paging');
    await c.execute(Sql.named("DELETE FROM users WHERE realm='customer' AND service=@s"), parameters: {'s': service});
    for (final k in ['d', 'b', 'e', 'a', 'c']) {
      await c.execute(Sql.named('INSERT INTO test_paging (code) VALUES (@k)'), parameters: {'k': k});
      await c.execute(Sql.named(CustomerAccounts.accountSessionSql),
          parameters: {'u': CustomerAccounts.accountLogin(service, '$k@x.example'), 's': service, 'n': 1});
    }
  });

  Future<List<String>> rows({int? limit, int offset = 0}) async {
    final l = await Db.asSystem(() => Orm.readAll<PageRow>(limit: limit, offset: offset));
    return [for (final r in l) r.code];
  }
  check('readAll without limit: every row by key',
      (await Db.asSystem(() => Orm.readAll<PageRow>())).map((r) => r.code).join() == 'abcde');
  check('readAll limit 2: 2 rows', (await rows(limit: 2)).join() == 'ab');
  check('readAll limit 2 offset 2: the next 2', (await rows(limit: 2, offset: 2)).join() == 'cd');
  check('readAll limit 2 offset 4: the last one', (await rows(limit: 2, offset: 4)).join() == 'e');
  check('readAll offset without limit: ignored (no LIMIT/OFFSET)', (await rows(offset: 3)).join() == 'abcde');

  String first(List<String> l) => l.map((e) => e[0]).join();
  final all = await Db.asSystem(() => CustomerAccounts.list(service));
  check('list without limit: every account by e-mail', first(all) == 'abcde' && all.first == 'a@x.example');
  check('list limit 2: 2 accounts', first(await Db.asSystem(() => CustomerAccounts.list(service, limit: 2))) == 'ab');
  check('list limit 2 offset 2: the next 2',
      first(await Db.asSystem(() => CustomerAccounts.list(service, limit: 2, offset: 2))) == 'cd');

  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute('DROP TABLE test_paging');
    await c.execute(Sql.named("DELETE FROM users WHERE realm='customer' AND service=@s"), parameters: {'s': service});
  });
  print('\nALL PASSED');
  exit(0);
}
