// Startup migration from the pre-0.1.0 Polish schema: tables, columns, indexes, RLS,
// permission keys, the `podglad` package and setting keys; a second start changes nothing.
// Run: tool/pg_test.sh test/migration_pg_test.dart

import 'package:ignis/engine/db.dart';
import 'package:ignis/engine/orm.dart';
import 'package:ignis/engine/schema.dart';
// ignore: unused_import — core entities come from ignisRegistry; this import documents which ones the test uses
import 'package:ignis/entities.dart';
import 'package:ignis/ignis_registry.g.dart';
import 'package:postgres/postgres.dart' show Sql;
import 'pg_guard.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

const _oldSchema = [
  'DROP SCHEMA public CASCADE',
  'CREATE SCHEMA public',
  "CREATE TABLE users (username text PRIMARY KEY, pass_hash text NOT NULL DEFAULT '', realm text NOT NULL DEFAULT 'staff', "
      'usluga bigint NOT NULL DEFAULT 0, zmien_haslo boolean NOT NULL DEFAULT false, totp text NOT NULL DEFAULT \'\', '
      'sesje_epoka bigint NOT NULL DEFAULT 0, ostatnie_logowanie bigint NOT NULL DEFAULT 0)',
  "CREATE TABLE permissions (key text PRIMARY KEY, description text NOT NULL DEFAULT '')",
  "CREATE TABLE packages (id text PRIMARY KEY, name text NOT NULL DEFAULT '', description text NOT NULL DEFAULT '', usluga bigint NOT NULL DEFAULT 0)",
  "CREATE TABLE package_permissions (id bigserial PRIMARY KEY, package_id text NOT NULL DEFAULT '', permission text NOT NULL DEFAULT '', UNIQUE (package_id, permission))",
  "CREATE TABLE user_packages (id bigserial PRIMARY KEY, username text NOT NULL DEFAULT '', package_id text NOT NULL DEFAULT '', UNIQUE (username, package_id))",
  "CREATE TABLE user_permissions (id bigserial PRIMARY KEY, username text NOT NULL DEFAULT '', permission text NOT NULL DEFAULT '', allow boolean NOT NULL DEFAULT true, UNIQUE (username, permission))",
  "CREATE TABLE settings (id text PRIMARY KEY, key text NOT NULL DEFAULT '', value text NOT NULL DEFAULT '', usluga bigint NOT NULL DEFAULT 0)",
  "CREATE TABLE dziennik (id bigserial PRIMARY KEY, usluga bigint NOT NULL DEFAULT 0, kto text NOT NULL DEFAULT '', gdzie text NOT NULL DEFAULT '', "
      "czynnosc text NOT NULL DEFAULT '', szczegol text NOT NULL DEFAULT '', cel bigint NOT NULL DEFAULT 0, ip text NOT NULL DEFAULT '', "
      "kiedy text NOT NULL DEFAULT '', wynik text NOT NULL DEFAULT 'ok')",
  'CREATE INDEX dziennik_kto_idx ON dziennik (kto)',
  "CREATE TABLE foldery (id bigserial PRIMARY KEY, usluga bigint NOT NULL DEFAULT 0, nazwa text NOT NULL DEFAULT '', sciezka text NOT NULL DEFAULT '/', "
      "rodzic bigint NOT NULL DEFAULT 0, utworzyl text NOT NULL DEFAULT '', utworzono text NOT NULL DEFAULT '', UNIQUE (sciezka, usluga))",
  "CREATE TABLE pliki (id bigserial PRIMARY KEY, usluga bigint NOT NULL DEFAULT 0, klucz text NOT NULL DEFAULT '', nazwa text NOT NULL DEFAULT '', "
      "sciezka text NOT NULL DEFAULT '/', typ text NOT NULL DEFAULT 'application/octet-stream', rozmiar bigint NOT NULL DEFAULT 0, "
      "skrot text NOT NULL DEFAULT '', wgral text NOT NULL DEFAULT '', wgrano text NOT NULL DEFAULT '', opis text NOT NULL DEFAULT '', UNIQUE (klucz))",
  "CREATE TABLE uslugi (id bigserial PRIMARY KEY, nazwa text NOT NULL DEFAULT '', slug text NOT NULL DEFAULT '', aktywna boolean NOT NULL DEFAULT true, "
      "limit_mb bigint NOT NULL DEFAULT 500, utworzono text NOT NULL DEFAULT '', zalozyl text NOT NULL DEFAULT '', UNIQUE (slug))",
  "CREATE TABLE domeny (id bigserial PRIMARY KEY, usluga bigint NOT NULL DEFAULT 0, domena text NOT NULL DEFAULT '', glowna boolean NOT NULL DEFAULT false, "
      "dodano text NOT NULL DEFAULT '', UNIQUE (domena))",
  // old policies read the old GUC — they must not survive (permissive policies are OR-ed)
  'ALTER TABLE pliki ENABLE ROW LEVEL SECURITY',
  'ALTER TABLE pliki FORCE ROW LEVEL SECURITY',
  "CREATE POLICY ignis_tenant ON pliki USING (current_setting('ignis.usluga', true) IN ('*', '0') OR usluga = 7)",
  "CREATE POLICY ignis_tenant_odczyt ON pliki FOR SELECT USING (current_setting('ignis.usluga', true) IN ('*', '0') OR usluga = 7)",
  // data
  "INSERT INTO uslugi (id, nazwa, slug, aktywna) VALUES (7, 'Demo', 'demo', true)",
  "INSERT INTO domeny (usluga, domena, glowna) VALUES (7, 'demo.test', true)",
  "INSERT INTO users (username, usluga, zmien_haslo, sesje_epoka, ostatnie_logowanie) VALUES ('ala', 7, true, 3, 99)",
  "INSERT INTO users (username, realm, usluga) VALUES ('k:7:jan@x.pl', 'customer', 7)",
  "INSERT INTO permissions (key, description) VALUES ('pliki.view', ''), ('pliki.foldery', 'Moje foldery'), "
      "('uzytkownicy.edit', 'Zakładanie, edycja i usuwanie użytkowników'), ('files.view', '')",
  "INSERT INTO packages (id, name, usluga) VALUES ('podglad', 'Podgląd', 0)",
  "INSERT INTO package_permissions (package_id, permission) VALUES ('podglad', 'pulpit.view'), ('podglad', 'pliki.*')",
  "INSERT INTO user_packages (username, package_id) VALUES ('ala', 'podglad')",
  "INSERT INTO user_permissions (username, permission, allow) VALUES ('ala', 'dziennik.view', false), ('ala', 'pliki.foldery', true)",
  "INSERT INTO settings (id, key, value, usluga) VALUES ('nazwa_serwisu@7', 'nazwa_serwisu', 'Demo', 7), ('stopka@0', 'stopka', 'F', 0)",
  "INSERT INTO dziennik (usluga, kto, gdzie, czynnosc, cel, kiedy, wynik) VALUES (7, 'ala', '/admin/pliki', 'wgraj', 0, '2026-01-01', 'odmowa'), (7, 'ala', '/admin/login', 'logowanie', 0, '2026-01-02', 'ok')",
  "INSERT INTO foldery (usluga, nazwa, sciezka, rodzic) VALUES (7, 'a', '/a/', 0)",
  "INSERT INTO pliki (usluga, klucz, nazwa, sciezka, rozmiar, opis) VALUES (7, 't7/x', 'x.txt', '/a/', 5, 'opis')",
];

Future<void> main() async {
  if (skipDestructive()) return;
  EntityRegistry.build(ignisRegistry);
  await Db.asSystem(() async {
    final c = await Db.connect();
    for (final q in _oldSchema) {
      await c.execute(q);
    }
  });

  await Schema.sync();

  await Db.asSystem(() async {
    final c = await Db.connect();
    Future<List<List<Object?>>> q(String sql) async => [for (final r in await c.execute(sql)) r.toList()];
    final tables = (await q("SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY 1")).map((r) => r[0]).toSet();
    check('old tables renamed, none left behind',
        tables.containsAll({'audit_log', 'folders', 'files', 'services', 'domains'}) &&
            tables.intersection({'dziennik', 'foldery', 'pliki', 'uslugi', 'domeny'}).isEmpty);
    check('users columns', (await q('SELECT service, must_change_password, session_epoch, last_login FROM users WHERE username = \'ala\'')).single
        .join(',') == '7,true,3,99');
    check('audit_log rows kept, result and sign-in actions in English',
        (await q('SELECT service, actor, location, action, result FROM audit_log ORDER BY occurred_at')).map((r) => r.join(',')).join(';') == '7,ala,/admin/pliki,wgraj,denied;7,ala,/admin/login,login,ok');
    check('files and folders rows', (await q('SELECT key, name, path, size, description FROM files')).single.join(',') == 't7/x,x.txt,/a/,5,opis' &&
        (await q('SELECT name, path, parent FROM folders')).single.join(',') == 'a,/a/,0');
    check('services and domains', (await q('SELECT name, active FROM services')).single.join(',') == 'Demo,true' &&
        (await q('SELECT domain, is_primary FROM domains')).single.join(',') == 'demo.test,true');
    final cols = (await q("SELECT table_name || '.' || column_name FROM information_schema.columns WHERE table_schema = 'public'")).map((r) => r[0]).toSet();
    check('no Polish columns left',
        !cols.any((c) => RegExp(r'\.(usluga|kto|gdzie|czynnosc|szczegol|cel|kiedy|wynik|nazwa|sciezka|rodzic|klucz|typ|rozmiar|skrot|wgral|wgrano|opis|aktywna|domena|glowna|dodano|zalozyl|utworzyl|utworzono|zmien_haslo|sesje_epoka|ostatnie_logowanie)$').hasMatch('$c')));
    final idx = (await q("SELECT indexname FROM pg_indexes WHERE schemaname = 'public'")).map((r) => r[0]).toSet();
    check('index renamed with its column', idx.contains('audit_log_actor_idx') && !idx.contains('dziennik_kto_idx'));
    check('permission keys migrated',
        (await q('SELECT key FROM permissions ORDER BY 1')).map((r) => r[0]).join(',') == 'files.folders,files.view,users.edit');
    check('package podglad → viewer with its grants',
        (await q("SELECT id FROM packages WHERE id IN ('podglad', 'viewer')")).map((r) => r[0]).join() == 'viewer' &&
            (await q("SELECT permission FROM package_permissions WHERE package_id = 'viewer' ORDER BY 1")).map((r) => r[0]).join(',') ==
                'dashboard.view,files.*' &&
            (await q("SELECT package_id FROM user_packages WHERE username = 'ala'")).single.first == 'viewer');
    check('seeded descriptions in English, edited ones kept',
        (await q("SELECT key, description FROM permissions WHERE key IN ('files.folders', 'users.edit') ORDER BY 1")).map((r) => r.join('=')).join(',') ==
                'files.folders=Moje foldery,users.edit=Create, edit and delete users' &&
            (await q("SELECT name FROM packages WHERE id = 'viewer'")).single.first == 'Viewer');
    check('customer login k: → c:',
        (await q("SELECT username FROM users WHERE realm = 'customer'")).single.first == 'c:7:jan@x.pl');
    check('user permissions migrated',
        (await q("SELECT permission, allow FROM user_permissions WHERE username = 'ala' ORDER BY 1")).map((r) => r.join(':')).join(',') ==
            'audit_log.view:false,files.folders:true');
    check('setting keys migrated with ids',
        (await q('SELECT id, key, value FROM settings ORDER BY 1')).map((r) => r.join(':')).join(',') ==
            'footer@0:footer:F,site_name@7:site_name:Demo');
    final policies = (await q("SELECT polname, pg_get_expr(polqual, polrelid) FROM pg_policy WHERE polrelid = 'files'::regclass ORDER BY 1"));
    check('RLS rebuilt on the new GUC, old read policy gone',
        policies.map((r) => r[0]).join(',') == 'ignis_tenant,ignis_tenant_read' &&
            policies.every((r) => '${r[1]}'.contains('ignis.service') && !'${r[1]}'.contains('ignis.usluga')));
    check('RLS check passes', (await Schema.checkRls(c)).isEmpty);
  });

  final rows = await Db.inContext(7, () async => (await (await Db.connect()).execute(Sql.named('SELECT count(*) FROM files'))).first[0]);
  check('service context sees its file through the new policy', rows == 1);
  final other = await Db.inContext(8, () async => (await (await Db.connect()).execute(Sql.named('SELECT count(*) FROM files'))).first[0]);
  check('another service sees nothing', other == 0);

  await Schema.sync();
  await Db.asSystem(() async {
    final c = await Db.connect();
    check('second start is a no-op', (await c.execute('SELECT count(*) FROM permissions')).first[0] == 3 &&
        (await c.execute("SELECT count(*) FROM settings WHERE key = 'footer'")).first[0] == 1);
  });
  await Db.close();
  print('\nALL PASSED');
}
