// IGNIS-050.2: RLS on an app tenant column (@Entity(tenantColumn:)). A row is visible/writable only when the column
// equals `ignis.tenant` (Db.asTenant) or in the system context; no tenant set = 0 rows (fail-closed).
// Plus an invariant generated from the EntityRegistry: every entity with tenantColumn has its policies and FORCE.
// Run: tool/pg_test.sh test/rls_tenant_pg_test.dart
import 'package:ignis/engine/annotations.dart';
import 'package:ignis/engine/db.dart';
import 'package:ignis/engine/orm.dart';
import 'package:ignis/engine/schema.dart';
// ignore: unused_import
import 'package:ignis/entities.dart';
import 'package:postgres/postgres.dart' show Sql;
import 'pg_guard.dart';
import 'registry_helper.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

class Note {
  int id = 0;
  String tenant = '';
  String body = '';
}

class Counter {
  int id = 0;
  int shop = 0;
}

Future<int> count([String table = 'test_tenant_notes']) async =>
    (await (await Db.connect()).execute('SELECT count(*) FROM $table')).first[0] as int;

Future<bool> rejected(Future<void> Function() f) async {
  try {
    await f();
    return false;
  } catch (_) {
    return true;
  }
}

Future<void> main() async {
  if (skipDestructive()) return;
  EntityRegistry.build(testRegistry(entities: [
    testEntity(const Entity('test_tenant_notes', tenantColumn: 'tenant'), Note, Note.new, [
      FieldMeta('id', int, (o) => (o as Note).id, (o, v) => (o as Note).id = v as int, defaultValue: 0),
      FieldMeta('tenant', String, (o) => (o as Note).tenant, (o, v) => (o as Note).tenant = v as String, defaultValue: ''),
      FieldMeta('body', String, (o) => (o as Note).body, (o, v) => (o as Note).body = v as String, defaultValue: ''),
    ]),
    testEntity(const Entity('test_tenant_counters', tenantColumn: 'shop'), Counter, Counter.new, [
      FieldMeta('id', int, (o) => (o as Counter).id, (o, v) => (o as Counter).id = v as int, defaultValue: 0),
      FieldMeta('shop', int, (o) => (o as Counter).shop, (o, v) => (o as Counter).shop = v as int, defaultValue: 0),
    ]),
  ]));
  await Schema.sync();
  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute('DELETE FROM test_tenant_notes');
    await c.execute('DELETE FROM test_tenant_counters');
    await c.execute("INSERT INTO test_tenant_notes (id, tenant, body) VALUES (1, 'a', 'x'), (2, 'a', 'y'), (3, 'b', 'z')");
    await c.execute('INSERT INTO test_tenant_counters (id, shop) VALUES (1, 7), (2, 8)');
  });

  check('no context — 0 rows (fail-closed)', await count() == 0);
  check('service context alone — 0 rows', await Db.inContext(1, count) == 0);
  check('platform context alone — 0 rows', await Db.asPlatform(count) == 0);
  check('tenant a sees its 2', await Db.asTenant('a', count) == 2);
  check('tenant b sees its 1', await Db.asTenant('b', count) == 1);
  check('asSystem sees all 3', await Db.asSystem(count) == 3);
  check('asSystem inside asTenant sees all, then the tenant view returns',
      await Db.asTenant('a', () async => (await Db.asSystem(count), await count())) == (3, 2));
  check('int tenant column: tenant "7" sees 1 row', await Db.asTenant('7', () => count('test_tenant_counters')) == 1);
  check('tenant a cannot update rows of b', await Db.asTenant('a', () async =>
      (await (await Db.connect()).execute("UPDATE test_tenant_notes SET body = 'hacked' WHERE tenant = 'b'")).affectedRows) == 0);
  check('tenant a cannot delete rows of b', await Db.asTenant('a', () async =>
      (await (await Db.connect()).execute("DELETE FROM test_tenant_notes WHERE tenant = 'b'")).affectedRows) == 0);
  check('tenant a cannot move its row to b (WITH CHECK)', await Db.asTenant('a', () => rejected(() async {
        await (await Db.connect()).runTx((tx) => tx.execute("UPDATE test_tenant_notes SET tenant = 'b' WHERE id = 1"));
      })));
  check('INSERT with a foreign tenant rejected (WITH CHECK)', await Db.asTenant('a', () => rejected(() async {
        await (await Db.connect()).runTx((tx) => tx.execute("INSERT INTO test_tenant_notes (id, tenant) VALUES (9, 'b')"));
      })));
  check('INSERT with own tenant accepted', await Db.asTenant('a', () async =>
      (await (await Db.connect()).execute("INSERT INTO test_tenant_notes (id, tenant) VALUES (10, 'a')")).affectedRows) == 1);
  check('b rows intact', await Db.asSystem(() async => (await (await Db.connect()).execute(
      "SELECT count(*) FROM test_tenant_notes WHERE tenant = 'b' AND body = 'z'")).first[0]) == 1);
  check('nested asTenant with another tenant throws (no mixing in one transaction)',
      await Db.asTenant('a', () => rejected(() => Db.asTenant('b', count))));
  check('nested asTenant with the same tenant runs', await Db.asTenant('a', () => Db.asTenant('a', count)) == 3);
  check('asTenant inside a request transaction throws', await Db.inContext(1, () => rejected(() => Db.asTenant('a', count))));
  check('empty tenant rejected', await rejected(() => Db.asTenant('', count)));
  check('tenant GUC does not outlive the transaction',
      (await (await Db.pool()).execute("SELECT coalesce(current_setting('ignis.tenant', true), '')")).first[0] == '');
  // Db.bindTenant: the tenant of a request transaction, bound after authentication
  check('bindTenant in a request transaction: only that tenant, before and after the first query',
      await Db.inContext(1, () async { final before = await count(); await Db.bindTenant('a'); return (before, await count()); }) == (0, 3) &&
          await Db.inContext(1, () async { await Db.bindTenant('b'); return count(); }) == 1);
  check('bindTenant survives Db.release (reopened transaction)',
      await Db.inContext(1, () async { await Db.bindTenant('a'); await count(); await Db.release(); return count(); }) == 3);
  check('bindTenant: same tenant again is a no-op, another throws',
      await Db.inContext(1, () async { await Db.bindTenant('a'); await Db.bindTenant('a');
        return rejected(() => Db.bindTenant('b')); }));
  check('bindTenant: asSystem inside still sees all', await Db.inContext(1, () async {
        await Db.bindTenant('a'); return (await Db.asSystem(count), await count()); }) == (4, 3));
  check('bindTenant outside a transaction / in system context / empty throws',
      await rejected(() => Db.bindTenant('a')) && await Db.asSystem(() => rejected(() => Db.bindTenant('a'))) &&
          await Db.inContext(1, () => rejected(() => Db.bindTenant(''))));
  check('Schema.checkRls clean', (await Db.asSystem(() async => Schema.checkRls(await Db.connect()))).isEmpty);

  // invariant generated from the registry: every entity with tenantColumn has ENABLE + FORCE and both policies
  final tenanted = [for (final n in EntityRegistry.names) EntityRegistry.byName(n)].where((m) => m.tenantColumn != null).toList();
  check('registry has tenant entities', tenanted.length == 2);
  for (final m in tenanted) {
    final r = await Db.asSystem(() async => (await Db.connect()).execute(
        Sql.named('''SELECT c.relrowsecurity, c.relforcerowsecurity,
                            (SELECT count(*) FROM pg_policy p WHERE p.polrelid = c.oid)
                     FROM pg_class c WHERE c.oid = to_regclass(@t)'''),
        parameters: {'t': '"${m.table}"'}));
    check('${m.table}: RLS + FORCE + 2 policies', r.first[0] == true && r.first[1] == true && r.first[2] == 2);
  }
  await Db.asSystem(() async => (await Db.connect()).execute('ALTER TABLE test_tenant_notes NO FORCE ROW LEVEL SECURITY'));
  check('checkRls reports a tenant table without FORCE', (await Db.asSystem(() async => Schema.checkRls(await Db.connect())))
      .any((e) => e.startsWith('test_tenant_notes')));
  await Schema.sync();
  check('sync restores FORCE', (await Db.asSystem(() async => Schema.checkRls(await Db.connect()))).isEmpty);
  await Db.close();
}
