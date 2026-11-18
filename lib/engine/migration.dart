// Rename of the pre-0.1.0 Polish schema to the English one. Runs at startup
// (IGNIS_SCHEMA=update) before the schema sync, in one transaction, and is a no-op
// once nothing old is left: each step fires only when the old name exists and the
// new one does not. RLS policies follow renamed columns inside Postgres; their
// fingerprint no longer matches, so Schema rebuilds them right after.
import 'dart:io';

import 'package:postgres/postgres.dart' show Sql;

class Migration {
  static const tables = {
    'dziennik': 'audit_log',
    'foldery': 'folders',
    'pliki': 'files',
    'uslugi': 'services',
    'domeny': 'domains',
  };

  /// Columns per (new) table name.
  static const columns = <String, Map<String, String>>{
    'audit_log': {
      'usluga': 'service', 'kto': 'actor', 'gdzie': 'location', 'czynnosc': 'action',
      'szczegol': 'detail', 'cel': 'target', 'kiedy': 'occurred_at', 'wynik': 'result',
    },
    'users': {
      'usluga': 'service', 'zmien_haslo': 'must_change_password',
      'sesje_epoka': 'session_epoch', 'ostatnie_logowanie': 'last_login',
    },
    'packages': {'usluga': 'service'},
    'settings': {'usluga': 'service'},
    'folders': {
      'usluga': 'service', 'nazwa': 'name', 'sciezka': 'path', 'rodzic': 'parent',
      'utworzyl': 'created_by', 'utworzono': 'created_at',
    },
    'files': {
      'usluga': 'service', 'klucz': 'key', 'nazwa': 'name', 'sciezka': 'path', 'typ': 'type',
      'rozmiar': 'size', 'skrot': 'hash', 'wgral': 'uploaded_by', 'wgrano': 'uploaded_at',
      'opis': 'description',
    },
    'services': {
      'nazwa': 'name', 'aktywna': 'active', 'utworzono': 'created_at', 'zalozyl': 'created_by',
    },
    'domains': {'usluga': 'service', 'domena': 'domain', 'glowna': 'is_primary', 'dodano': 'added_at'},
  };

  /// Permission sections (`pliki.view` → `files.view`, also patterns like `pliki.*`).
  static const permissionSections = {
    'pulpit': 'dashboard', 'ustawienia': 'settings', 'uprawnienia': 'permissions',
    'uzytkownicy': 'users', 'dziennik': 'audit_log', 'pliki': 'files',
  };
  static const permissions = {'files.foldery': 'files.folders'};
  static const packages = {'podglad': 'viewer'};
  static const settingKeys = {
    'nazwa_serwisu': 'site_name', 'url_bazowy': 'base_url', 'kontakt_email': 'contact_email',
    'strefa_czasowa': 'timezone', 'stopka': 'footer',
  };

  /// Audit log `result` values.
  static const auditResults = {'odmowa': 'denied', 'blad': 'error'};

  /// Audit log actions written by the engine itself (sign-in).
  static const auditActions = {
    'logowanie': 'login', 'logowanie_2fa': 'login_2fa', 'logowanie_blokada': 'login_locked',
    'logowanie_2fa_blokada': 'login_2fa_locked', 'Blokada 2FA': '2fa_locked',
  };

  /// Seeded permission descriptions; a description someone edited stays as it is.
  static const permissionDescriptions = {
    'Dostęp do pulpitu': 'Access to the dashboard',
    'Podgląd ustawień serwisu': 'View site settings',
    'Zmiana ustawień serwisu': 'Change site settings',
    'Podgląd pakietów i uprawnień': 'View packages and permissions',
    'Tworzenie i zmiana pakietów': 'Create and change packages',
    'Podgląd użytkowników': 'View users',
    'Zakładanie, edycja i usuwanie użytkowników': 'Create, edit and delete users',
    'Podgląd dziennika operacji': 'View the audit log',
    'Podgląd menedżera plików': 'View the file manager',
    'Wgrywanie plików': 'Upload files',
    'Zmiana nazwy, opisu i przenoszenie plików': 'Rename, describe and move files',
    'Usuwanie plików': 'Delete files',
    'Tworzenie i usuwanie folderów': 'Create and delete folders',
  };

  /// Seeded packages: id → (old name, old description, name, description).
  static const seededPackages = {
    'root': ('Root', 'Pełny dostęp do wszystkiego', 'Root', 'Full access to everything'),
    'viewer': ('Podgląd', 'Tylko odczyt', 'Viewer', 'Read-only'),
  };

  static Future<void> run(dynamic c) async {
    await c.runTx((tx) async {
      Future<bool> hasTable(String t) async =>
          (await tx.execute(Sql.named('SELECT to_regclass(@t) IS NOT NULL'), parameters: {'t': t})).first[0] as bool;
      Future<Set<String>> columnsOf(String t) async => {
            for (final r in await tx.execute(
                Sql.named('SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name=@t'),
                parameters: {'t': t}))
              r[0] as String,
          };

      for (final MapEntry(key: old, value: fresh) in tables.entries) {
        if (await hasTable(old) && !await hasTable(fresh)) {
          await tx.execute('ALTER TABLE "$old" RENAME TO "$fresh"');
          stdout.writeln('  ~ table $old → $fresh');
        }
      }
      for (final MapEntry(key: table, value: renames) in columns.entries) {
        if (!await hasTable(table)) continue;
        final present = await columnsOf(table);
        final oldTable = tables.entries.where((e) => e.value == table).firstOrNull?.key ?? table;
        for (final MapEntry(key: old, value: fresh) in renames.entries) {
          if (!present.contains(old) || present.contains(fresh)) continue;
          await tx.execute('ALTER TABLE "$table" RENAME COLUMN "$old" TO "$fresh"');
          // indexes created by Schema are named <table>_<column>_idx
          await tx.execute('ALTER INDEX IF EXISTS "${oldTable}_${old}_idx" RENAME TO "${table}_${fresh}_idx"');
          stdout.writeln('  ~ column $table.$old → $fresh');
        }
      }

      final perm = {
        for (final MapEntry(key: o, value: n) in permissionSections.entries) ...{'$o.': '$n.'},
        for (final MapEntry(key: o, value: n) in permissions.entries) o: n,
      };
      for (final (table, column, owner) in const [
        ('permissions', 'key', null),
        ('package_permissions', 'permission', 'package_id'),
        ('user_permissions', 'permission', 'username'),
      ]) {
        if (!await hasTable(table)) continue;
        for (final MapEntry(key: o, value: n) in perm.entries) {
          final prefix = o.endsWith('.');
          final match = prefix ? "$column LIKE @o || '%'" : '$column = @o';
          final renamed = prefix ? '@n || substr($column, ${o.length + 1})' : '@n';
          // a row already carrying the new value wins; the old duplicate goes
          await tx.execute(
              Sql.named('DELETE FROM "$table" t WHERE ${match.replaceAll(column, 't.$column')} AND EXISTS '
                  '(SELECT 1 FROM "$table" x WHERE x.$column = ${renamed.replaceAll(column, 't.$column')}'
                  '${owner == null ? '' : ' AND x.$owner = t.$owner'})'),
              parameters: {'o': o, 'n': n});
          await tx.execute(Sql.named('UPDATE "$table" SET $column = $renamed WHERE $match'), parameters: {'o': o, 'n': n});
        }
      }

      if (await hasTable('packages')) {
        for (final MapEntry(key: o, value: n) in packages.entries) {
          final moved = await tx.execute(
              Sql.named('UPDATE packages SET id = @n WHERE id = @o AND NOT EXISTS (SELECT 1 FROM packages WHERE id = @n)'),
              parameters: {'o': o, 'n': n});
          if ((moved.affectedRows as int) == 0) continue;
          for (final t in const ['package_permissions', 'user_packages']) {
            if (await hasTable(t)) {
              await tx.execute(Sql.named('UPDATE "$t" SET package_id = @n WHERE package_id = @o'), parameters: {'o': o, 'n': n});
            }
          }
          stdout.writeln('  ~ package $o → $n');
        }
      }

      if (await hasTable('audit_log') && (await columnsOf('audit_log')).containsAll(const {'result', 'action'})) {
        for (final (column, values) in const [('result', auditResults), ('action', auditActions)]) {
          for (final MapEntry(key: o, value: n) in values.entries) {
            await tx.execute(Sql.named('UPDATE audit_log SET $column = @n WHERE $column = @o'), parameters: {'o': o, 'n': n});
          }
        }
      }

      if (await hasTable('permissions') && (await columnsOf('permissions')).contains('description')) {
        for (final MapEntry(key: o, value: n) in permissionDescriptions.entries) {
          await tx.execute(Sql.named('UPDATE permissions SET description = @n WHERE description = @o'), parameters: {'o': o, 'n': n});
        }
      }
      if (await hasTable('packages') && (await columnsOf('packages')).containsAll(const {'name', 'description'})) {
        for (final MapEntry(key: id, value: (oName, oDesc, nName, nDesc)) in seededPackages.entries) {
          await tx.execute(Sql.named('UPDATE packages SET name = @nn WHERE id = @i AND name = @on'),
              parameters: {'i': id, 'on': oName, 'nn': nName});
          await tx.execute(Sql.named('UPDATE packages SET description = @nd WHERE id = @i AND description = @od'),
              parameters: {'i': id, 'od': oDesc, 'nd': nDesc});
        }
      }

      // Customer account logins: `k:<service>:<email>` → `c:<service>:<email>`. Staff logins cannot contain `:`.
      for (final (table, column) in const [
        ('users', 'username'), ('user_packages', 'username'), ('user_permissions', 'username'), ('audit_log', 'actor'),
      ]) {
        if (await hasTable(table) && (await columnsOf(table)).contains(column)) {
          await tx.execute("UPDATE \"$table\" SET $column = 'c:' || substr($column, 3) WHERE $column LIKE 'k:%:%'");
        }
      }

      if (await hasTable('settings') && (await columnsOf('settings')).contains('service')) {
        for (final MapEntry(key: o, value: n) in settingKeys.entries) {
          await tx.execute(
              Sql.named("UPDATE settings s SET key = @n, id = @n || '@' || s.service WHERE s.key = @o AND NOT EXISTS "
                  '(SELECT 1 FROM settings x WHERE x.key = @n AND x.service = s.service)'),
              parameters: {'o': o, 'n': n});
        }
      }
    });
  }
}
