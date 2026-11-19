// SEC-A-2: RLS fail-closed. Bez kontekstu tabela z `usluga` zwraca 0 wierszy; usługa widzi swoje; platforma
// i Db.jakoSystem — wszystko. Kontekst żyje w transakcji (set_config lokalnie), a sesja żądania po jego końcu
// rzuca zamiast wykonać zapytanie na cudzym połączeniu.
// Uruchomienie: tool/pg_test.sh test/rls_pg_test.dart
import 'dart:io';

import 'package:ignis/engine/db.dart';
import 'package:ignis/engine/orm.dart';
import 'package:ignis/engine/schema.dart';
// ignore: unused_import — encje rdzenia rejestrują się przez mirrors (EntityRegistry.build)
import 'package:ignis/entities.dart';
import 'package:postgres/postgres.dart' show Sql;
import 'pg_guard.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<int> count() async =>
    (await (await Db.connect()).execute("SELECT count(*) FROM settings WHERE key LIKE 'rlstest.%'")).first[0] as int;

Future<void> main(List<String> a) async {
  if (skipDestructive()) return;
  EntityRegistry.build();
  if (a.contains('tylko-sync')) {
    await Schema.sync(); // proces potomny (FIX-13): rzuca → kod wyjścia ≠ 0
    exit(0);
  }
  await Schema.sync();
  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute("DELETE FROM settings WHERE key LIKE 'rlstest.%'");
    for (final u in [1, 1, 2]) {
      await c.execute(
          Sql.named("INSERT INTO settings (id, key, value, service) VALUES (@i, @k, '', @u)"),
          parameters: {'i': 'rlstest.${DateTime.now().microsecondsSinceEpoch}@$u', 'k': 'rlstest.$u', 'u': u});
    }
  });

  check('bez kontekstu — 0 wierszy (fail-closed)', await count() == 0);
  check('usługa 1 widzi swoje 2', await Db.inContext(1, count) == 2);
  check('usługa 2 widzi swój 1', await Db.inContext(2, count) == 1);
  check('platforma widzi 3', await Db.asPlatform(count) == 3);
  check('kontekst systemowy widzi 3', await Db.asSystem(count) == 3);
  check('jakoSystem w żądaniu usługi podnosi i przywraca kontekst',
      await Db.inContext(1, () async => (await Db.asSystem(count), await count())) == (3, 2));
  check('usługa nie wpisze wiersza innej usługi (WITH CHECK)', await Db.inContext(1, () async {
    try {
      await (await Db.connect()).runTx((tx) => tx.execute(
          "INSERT INTO settings (id, key, value, service) VALUES ('rlstest.obcy@2', 'rlstest.2', '', 2)"));
      return false;
    } catch (_) {
      return true;
    }
  }));
  // PERF-A-3: jakoPlatforma w żądaniu — to samo połączenie, kontekst wraca
  check('jakoPlatforma w żądaniu usługi: ta sama transakcja, kontekst wraca',
      await Db.inContext(1, () async {
        final pid = (await (await Db.connect()).execute('SELECT pg_backend_pid()')).first[0];
        final (w, p) = await Db.asPlatform(() async =>
            (await count(), (await (await Db.connect()).execute('SELECT pg_backend_pid()')).first[0]));
        return (w, p == pid, await count());
      }) == (3, true, 2));
  Future<String> policies() async => (await (await Db.connect()).execute(
          "SELECT string_agg(oid::text, ',' ORDER BY oid) FROM pg_policy WHERE polrelid = 'settings'::regclass")).first[0] as String;
  final before = await Db.asSystem(policies);
  await Schema.sync();
  check('drugi Schema.sync nie przebudowuje polityk RLS (te same oid)', '${await Db.asSystem(policies)}' == '$before');
  check('indeks na foldery.parent i dziennik.occurred_at', (await Db.asSystem(() async => (await (await Db.connect()).execute(
          "SELECT count(*) FROM pg_indexes WHERE (tablename, indexdef ~ '\\(parent\\)') = ('folders', true) "
          "OR (tablename, indexdef ~ '\\(occurred_at\\)') = ('audit_log', true)")).first[0])) == 2);
  check('indeks na user_packages.package_id (FIX-46)', (await Db.asSystem(() async => (await (await Db.connect()).execute(
          "SELECT count(*) FROM pg_indexes WHERE tablename = 'user_packages' AND indexdef ~ '\\(package_id\\)'")).first[0])) == 1);
  await Db.asSystem(() async => (await Db.connect())
      .execute("COMMENT ON POLICY ${Schema.readPolicy} ON settings IS 'ignis:stary'"));
  await Schema.sync();
  check('zmieniony odcisk → polityki odtworzone', '${await Db.asSystem(policies)}' != '$before');
  check('…i dalej działają', await Db.inContext(1, count) == 2 && await count() == 0);

  // FIX-4: jakoSystem poza żądaniem — jedna transakcja, '*' lokalnie (PgBouncer transaction pooling)
  Future<Object?> q(String sql) async => (await (await Db.connect()).execute(sql)).first[0];
  check('jakoSystem: jedna transakcja (ten sam txid w kolejnych instrukcjach)',
      await Db.asSystem(() async => await q('SELECT txid_current()') == await q('SELECT txid_current()')));
  check('jakoSystem: kontekst lokalny w transakcji (set_config is_local)',
      await Db.asSystem(() async => await q("SELECT current_setting('ignis.service')")) == '*');
  try {
    await Db.asSystem(() async {
      await (await Db.connect()).execute("INSERT INTO settings (id, key, value, service) VALUES ('rlstest.tx@1', 'rlstest.1', '', 1)");
      throw StateError('x');
    });
  } on StateError catch (_) {}
  check('jakoSystem: wyjątek cofa całość', await Db.inContext(1, count) == 2);
  check('jakoSystemSesyjnie: bez transakcji (każda instrukcja osobno)',
      await Db.asSystemSession(() async => await q('SELECT txid_current()') != await q('SELECT txid_current()')));

  check('po żądaniu połączenia w puli nie mają kontekstu',
      (await (await Db.pool()).execute("SELECT coalesce(current_setting('ignis.service', true), '')")).first[0] == '');

  print('SEC-A-3 — zapis ściśle w swojej usłudze:');
  await Db.asSystem(() async {
    final c = await Db.connect();
    for (final t in ['user_packages', 'user_permissions']) {
      await c.execute("DELETE FROM $t WHERE username LIKE 'rlstest%'");
    }
    await c.execute("DELETE FROM users WHERE username LIKE 'rlstest%'");
    await c.execute("DELETE FROM audit_log WHERE location = 'rlstest'");
    await c.execute("INSERT INTO packages (id, name, description, service) VALUES ('root', 'Root', '', 0) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name");
    await c.execute("INSERT INTO users (username, pass_hash, realm, service) VALUES ('rlstest_plat', 'h', 'staff', 0), "
        "('rlstest_u1', 'h', 'staff', 1)");
    await c.execute("INSERT INTO audit_log (service, actor, location, action, detail, target, ip, occurred_at) "
        "VALUES (0, 'plat', 'rlstest', 'x', '', 1, '', '')");
  });
  Future<int> inService1(String sql) => Db.inContext(1, () async {
        try {
          return (await (await Db.connect()).runTx((tx) => tx.execute(sql))).affectedRows;
        } catch (_) {
          return -1;
        }
      });
  check('usługa nie widzi konta platformy (hash, totp)', await Db.inContext(1, () async =>
      (await (await Db.connect()).execute("SELECT 1 FROM users WHERE username='rlstest_plat'")).length) == 0);
  check('a login platformy i tak zajęty (UNIQUE ponad RLS)',
      await inService1("INSERT INTO users (username, pass_hash, realm, service) VALUES ('rlstest_plat', '', 'staff', 1) "
              'ON CONFLICT DO NOTHING') == 0);
  check('ale nie zmieni jego hasła', await inService1("UPDATE users SET pass_hash='x' WHERE username='rlstest_plat'") == 0);
  check('ani go nie usunie', await inService1("DELETE FROM users WHERE username='rlstest_plat'") == 0);
  check('ani nie założy konta platformy',
      await inService1("INSERT INTO users (username, pass_hash, realm, service) VALUES ('rlstest_nowy', '', 'staff', 0)") == -1);
  check('widzi wpis platformy o sobie, ale go nie skasuje',
      await inService1("DELETE FROM audit_log WHERE location='rlstest'") == 0);
  check('nie podrobi wpisu platformy',
      await inService1("INSERT INTO audit_log (service, actor, location, action, detail, target, ip, occurred_at) "
              "VALUES (0, 'x', 'rlstest', 'x', '', 1, '', '')") == -1);
  check('nie podepnie pakietu root swojemu kontu',
      await inService1("INSERT INTO user_packages (username, package_id) VALUES ('rlstest_u1', 'root')") == -1);
  check('nie nada grantu kontu platformy',
      await inService1("INSERT INTO user_permissions (username, permission, allow) VALUES ('rlstest_plat', 'x', false)") == -1);
  check('nie zmieni swojego limitu miejsca', await inService1('UPDATE services SET limit_mb = 0') == 0);
  check('nada grant swojemu kontu',
      await inService1("INSERT INTO user_permissions (username, permission, allow) VALUES ('rlstest_u1', 'x', true)") == 1);

  late DbSession leak;
  await Db.inContext(1, () async => leak = await Db.connect());
  Object? error;
  try {
    await leak.execute('SELECT 1');
  } catch (e) {
    error = e;
  }
  check('sesja żądania użyta po jego końcu rzuca StateError', error is StateError);

  print('SEC-A-4 — brak polityki przerywa start:');
  check('po sync — zero rozjazdów', (await Db.asSystem(() async => Schema.checkRls(await Db.connect()))).isEmpty);
  await Db.asSystem(() async => (await Db.connect()).execute('DROP POLICY ignis_tenant_read ON settings'));
  await Db.asSystem(() async => (await Db.connect()).execute('CREATE POLICY obca ON files USING (true)'));
  final mismatches = await Db.asSystem(() async => Schema.checkRls(await Db.connect()));
  check('zdjęta polityka i obca polityka wykryte',
      mismatches.any((r) => r.startsWith('settings:')) && mismatches.any((r) => r.startsWith('files:')));
  Object? start;
  try {
    // update odtwarza polityki settings, ale obcej nie zdejmuje — start ma paść
    await Schema.sync();
  } catch (e) {
    start = e;
  }
  check('Schema.sync rzuca przy obcej polityce', start is StateError && '$start'.contains('files'));
  await Db.asSystem(() async => (await Db.connect()).execute('DROP POLICY obca ON files'));
  await Schema.sync();
  check('po zdjęciu obcej polityki start przechodzi', true);

  print('FIX-13 — superuser / BYPASSRLS nie wystartuje:');
  final su = await Process.run(Platform.resolvedExecutable, ['run', Platform.script.toFilePath(), 'tylko-sync'],
      environment: {'IGNIS_DB_USER': 'ig', 'IGNIS_DB_PASS': 'ig', 'IGNIS_SCHEMA': 'none'});
  check('Schema.sync na superuserze rzuca (IGNIS_SCHEMA=none też)',
      su.exitCode != 0 && '${su.stdout}${su.stderr}'.contains('BYPASSRLS'));

  // FIX-35: ta sama nazwa, inny warunek (ręczna podmiana / stara wersja) — wykryta po odcisku
  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute('DROP POLICY ignis_tenant_read ON files');
    await c.execute('CREATE POLICY ignis_tenant_read ON files FOR SELECT USING (true)');
  });
  check('podmieniony warunek polityki wykryty',
      (await Db.asSystem(() async => Schema.checkRls(await Db.connect()))).any((r) => r.startsWith('files:')));
  await Schema.sync(); // update odtwarza politykę z odciskiem
  check('po update odcisk znów zgodny', (await Db.asSystem(() async => Schema.checkRls(await Db.connect()))).isEmpty);

  await Db.close();
  print('\nALL PASSED');
}
