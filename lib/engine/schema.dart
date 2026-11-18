// ============================================================================
//  schema.dart — AUTO-SCHEMA from reflection (the equivalent of hibernate.hbm2ddl.auto)
// ----------------------------------------------------------------------------
//  Since EntityRegistry knows the fields of every @Entity anyway, the same source is enough
//  to produce DDL. Instead of writing and deploying migration files, the node at startup
//  BRINGS the schema in line with the classes.
//
//  Modes (env IGNIS_SCHEMA), as in Hibernate:
//    update   — creates missing tables and ADDS missing columns (default)
//    validate — changes nothing, only prints mismatches and stops startup
//    none     — skips everything (when someone else manages the schema)
//
//  ⚠️ DELIBERATE LIMITS (the same as `update` in Hibernate):
//    • does not drop columns or tables — a removed field stays in the database as an orphan,
//    • does not change the type of an existing column,
//    • does not rename (renaming a field = new column + orphaned old one; see migration.dart for the core rename).
//  Such changes are done with manual SQL. On purpose: an automaton that DROPs
//  columns will sooner or later eat production data over a typo in a field.
// ============================================================================

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:postgres/postgres.dart' show Sql; // Sql only — postgres exports its own `Type`

import 'db.dart';
import 'migration.dart';
import 'orm.dart';

class Schema {
  /// Field defaults — read from a FRESH entity instance via mirrors.
  /// So `String realm = 'staff'` in the class gives `DEFAULT 'staff'` in DDL,
  /// and adding a column to an existing table does not leave NULLs in the rows.
  static Map<String, Object?> _defaults(EntityMeta m) {
    try {
      final inst = m.cm.newInstance(const Symbol(''), const []);
      return {
        for (final f in m.fields) f.name: inst.getField(Symbol(f.name)).reflectee,
      };
    } catch (_) {
      return const {}; // no no-arg constructor — no defaults
    }
  }

  static String _sqlLiteral(Object? v) => switch (v) {
        String s => "'${s.replaceAll("'", "''")}'",
        bool b => b.toString(),
        num n => n.toString(),
        _ => 'NULL',
      };

  /// Column type for a Dart field type. The PK gets `bigserial` (the database assigns the id).
  static String _type(Type t, {required bool pk}) {
    if (pk && (t == int || t.toString() == 'int?')) return 'bigserial PRIMARY KEY';
    final n = t.toString().replaceAll('?', '');
    final sql = switch (n) {
      'int' => 'bigint',
      'double' => 'double precision',
      'bool' => 'boolean', // DEFAULT is added by _defaults() from the field value
      'DateTime' => 'timestamptz',
      _ => 'text',
    };
    return pk ? '$sql PRIMARY KEY' : sql;
  }

  /// Columns the data layer always filters by. Without an index every
  /// `WHERE service=@s` is a full table scan — milliseconds today, but it grows linearly.
  static const _indexed = {
    'service', 'hash', 'message_id', 'path',
    'action',
    // audit_log: a customer filters by `target` (platform operations on it), and the list
    // always goes by `actor` with the author filter
    'target', 'actor',
  };

  /// Indexes of specific core tables (not by column name alone — the same name may appear
  /// in large app tables, where CREATE INDEX at startup would block writes).
  static const _tableIndexes = {
    'folders': ['parent'], // folder tree
    'audit_log': ['occurred_at'], // list and cleanup by date
    'user_packages': ['package_id'], // package holders; the unique index starts with username
  };

  /// Uniqueness that makes sense only for some rows. A plain UNIQUE does not
  /// tell "no number" from "the same number", and there may be many drafts without a number.
  static const _partialIndexes = {
  };

  static Future<void> _createPartialIndexes(EntityMeta m, dynamic c) async {
    for (final (name, columns, condition) in _partialIndexes[m.table] ?? const []) {
      try {
        await c.execute('CREATE UNIQUE INDEX IF NOT EXISTS "$name" '
            'ON "${m.table}" ($columns) WHERE $condition');
      } catch (e) {
        stdout.writeln('  ! ${m.table}: indeks $name — $e');
      }
    }
  }

  static Future<void> _indexes(EntityMeta m, dynamic c, String mode) async {
    if (mode == 'validate') return; // a missing index is not a schema mismatch
    final tableIndexCols = _tableIndexes[m.table] ?? const [];
    for (final f in m.fields.where((f) => f.name != m.pk && (_indexed.contains(f.name) || tableIndexCols.contains(f.name)))) {
      await c.execute('CREATE INDEX IF NOT EXISTS "${m.table}_${f.name}_idx" '
          'ON "${m.table}" ("${f.name}")');
    }
  }

  // ─────────────────────────── RLS ───────────────────────────
  //  The last line of tenant isolation. The `service=@s` filter in queries stays
  //  the first one — RLS is there to catch what the code misses, not to replace diligence.
  //
  //  The policy reads `ignis.service` (set by `Db.inContext` locally in the request
  //  transaction, or by `Db.asSystem`). FAIL-CLOSED:
  //    • missing / empty / garbage — 0 rows (a forgotten context shows nothing),
  //    • '*'            — system context (seed, schema, CLI, cleanup): full access,
  //    • '0'            — platform panel: full access (it manages everyone),
  //    • a number       — only that service's rows.
  //
  //  The app role OWNS the tables, and the owner bypasses RLS by default —
  //  hence FORCE. Without it the policies would look enabled and do nothing.

  static const _policyName = 'ignis_tenant';

  /// Policy from before the GUC rename. It MUST go: permissive policies are combined with OR,
  /// and the old one reads a GUC that is no longer set (NULL = full access) and would disable isolation.
  static const _legacyPolicies = ['ccms_tenant', 'ignis_tenant_odczyt'];

  static const _ctx = "current_setting('ignis.service', true)";

  /// Context as a number or NULL — CASE, because `'*'::int` would break the query.
  static const _service = "CASE WHEN $_ctx ~ '^[0-9]+\$' THEN $_ctx::int END";

  /// Read policy added to the shared one (write + read). Permissive policies are combined with OR.
  static const _readPolicy = 'ignis_tenant_read';
  static const readPolicy = _readPolicy;

  /// Whether the entity's table gets row-level security (a policy from [_policy]).
  static bool rlsScoped(EntityMeta m) => _policy(m) != null;

  /// (read, write) for a table, or null — a table without service data. Writing is STRICT:
  /// read exceptions (platform accounts, platform entries about the service) do not give the right to
  /// change or forge them from a service context (SEC-A-3). Grant tables have no
  /// `service` column — they belong to a service through the account and the package.
  static (String, String)? _policy(EntityMeta m) {
    final t = '"${m.table}"';
    const own = 'service = $_service';
    final account = 'EXISTS (SELECT 1 FROM users u WHERE u.username = $t.username AND u.service = $_service)';
    final package = 'EXISTS (SELECT 1 FROM packages p WHERE p.id = $t.package_id AND p.service = $_service)';
    return switch (m.table) {
      // no exception for platform accounts: RLS does not cut columns, and operators' pass_hash and totp must not
      // be reachable from a service context; UNIQUE(username) sees all rows anyway
      'users' => (own, own),
      // a service sees platform entries about its site
      'audit_log' => ('$own OR target = $_service', own),
      'user_packages' => (account, '$account AND $package'),
      'user_permissions' => (account, account),
      'package_permissions' => (package, package),
      // a service sees its own row (space limit, name); only the platform changes it
      'services' => ('id = $_service', 'false'),
      _ when m.fields.any((f) => f.name == 'service') => (own, own),
      _ => null,
    };
  }

  /// (read, write, fingerprint) of a table's policies, or null. The fingerprint of the conditions goes into the policy comment:
  /// Postgres rewrites the expression text, so we compare the fingerprint, not the text. A matching state = we touch
  /// nothing (no ACCESS EXCLUSIVE on every startup; PERF-A-3).
  static (String, String, String)? _conditions(EntityMeta m) {
    final fieldsCount = _policy(m);
    if (fieldsCount == null) return null;
    const full = "$_ctx IN ('*', '0')";
    final (read, stored) = ('$full OR ${fieldsCount.$1}', '$full OR ${fieldsCount.$2}');
    return (read, stored, 'ignis:${sha256.convert(utf8.encode('$read\n$stored'))}');
  }

  /// Enables RLS on a table: a FOR ALL policy with a strict write condition and FOR SELECT
  /// with the read condition. '*' (system) and '0' (platform) — full access.
  static Future<void> _rls(EntityMeta m, dynamic c, String mode) async {
    if (mode == 'validate') return;
    final w = _conditions(m);
    if (w == null) return;
    final (read, stored, fingerprint) = w;
    final present = await c.execute(
        Sql.named('''SELECT c.relrowsecurity AND c.relforcerowsecurity,
                            (SELECT string_agg(p.polname || '=' || coalesce(obj_description(p.oid, 'pg_policy'), ''), ',' ORDER BY p.polname)
                             FROM pg_policy p WHERE p.polrelid = c.oid)
                     FROM pg_class c WHERE c.oid = to_regclass(@t)'''),
        parameters: {'t': '"${m.table}"'});
    final expected = ([_policyName, _readPolicy]..sort()).map((n) => '$n=$fingerprint').join(',');
    if (present.isNotEmpty && present.first[0] == true && present.first[1] == expected) {
      return;
    }
    // no try: a node without the last line of isolation must not start (SEC-A-4). In a transaction:
    // no request lands in the moment between DROP and CREATE (a table without policies = 0 rows).
    await c.runTx((tx) async {
      await tx.execute('ALTER TABLE "${m.table}" ENABLE ROW LEVEL SECURITY');
      await tx.execute('ALTER TABLE "${m.table}" FORCE ROW LEVEL SECURITY');
      for (final n in [..._legacyPolicies, _policyName, _readPolicy]) {
        await tx.execute('DROP POLICY IF EXISTS $n ON "${m.table}"');
      }
      await tx.execute('CREATE POLICY $_policyName ON "${m.table}" USING ($stored) WITH CHECK ($stored)');
      await tx.execute('CREATE POLICY $_readPolicy ON "${m.table}" FOR SELECT USING ($read)');
      for (final n in [_policyName, _readPolicy]) {
        await tx.execute("COMMENT ON POLICY $n ON \"${m.table}\" IS '$fingerprint'");
      }
    });
  }

  /// RLS mismatches in the database: a table under isolation without ENABLE/FORCE or without the full set
  /// of policies, with a foreign policy (permissive ones are combined with OR and would open access), or with a policy
  /// whose fingerprint does not match the conditions in code (old version, manual swap via DROP/CREATE).
  /// Checked in EVERY mode, also `validate` and `none` — any mismatch stops startup.
  static Future<List<String>> checkRls(dynamic c) async {
    final errors = <String>[];
    // FORCE does not bind a superuser or a role with BYPASSRLS — the policies would exist but stop nobody
    final role = await c.execute('SELECT current_user::text, rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user');
    if (role.isNotEmpty && role.first[1] == true) {
      errors.add('role "${role.first[0]}" is a superuser or has BYPASSRLS — RLS does not apply to it; '
          'set IGNIS_DB_USER to a regular role (table owner, NOSUPERUSER NOBYPASSRLS)');
    }
    for (final name in EntityRegistry.names) {
      final m = EntityRegistry.byName(name);
      final w = _conditions(m);
      if (w == null) continue;
      final r = await c.execute(
          Sql.named('''SELECT c.relrowsecurity AND c.relforcerowsecurity,
                              array(SELECT p.polname::text FROM pg_policy p WHERE p.polrelid = c.oid ORDER BY 1),
                              array(SELECT coalesce(obj_description(p.oid, 'pg_policy'), '')
                                    FROM pg_policy p WHERE p.polrelid = c.oid ORDER BY p.polname)
                       FROM pg_class c WHERE c.oid = to_regclass(@t)'''),
          parameters: {'t': '"${m.table}"'});
      if (r.isEmpty) continue; // a missing table is reported by validate separately
      final policies = (r.first[1] as List).cast<String>().toSet();
      if (r.first[0] != true) errors.add('${m.table}: RLS disabled or without FORCE');
      if (!policies.containsAll({_policyName, _readPolicy}) || policies.length != 2) {
        errors.add('${m.table}: polityki ${policies.join(', ')} (oczekiwane $_policyName, $_readPolicy)');
      } else if (!(r.first[2] as List).every((o) => o == w.$3)) {
        errors.add('${m.table}: policy conditions do not match the code (fingerprint ≠ ${w.$3})');
      }
    }
    return errors;
  }

  /// Session advisory lock taken by [sync] and `Seed.seed` (same key there): nodes starting at once would
  /// otherwise race on CREATE TABLE / ADD COLUMN and on the initial admin account.
  static const _startLock = 0x49676e73;

  /// Brings the database schema in line with the @Entity classes.
  static Future<void> sync() async {
    final mode = Platform.environment['IGNIS_SCHEMA'] ?? 'update';
    await Db.asSystemSession(() async {
      final c = await Db.connect();
      await c.execute('SELECT pg_advisory_lock($_startLock)');
      try {
        if (mode != 'none') await _sync(mode);
        final rls = await checkRls(c);
        if (rls.isNotEmpty) {
          throw StateError('RLS does not match the code — the node will not start without service isolation:\n  • ${rls.join('\n  • ')}');
        }
      } finally {
        await c.execute('SELECT pg_advisory_unlock($_startLock)');
      }
    });
  }

  static Future<void> _sync(String mode) async {

    final c = await Db.connect();
    final mismatches = <String>[];
    if (mode == 'update') await Migration.run(c);

    for (final name in EntityRegistry.names) {
      final m = EntityRegistry.byName(name);

      final exists = (await c.execute(
        Sql.named('SELECT to_regclass(@t) IS NOT NULL'),
        parameters: {'t': m.table},
      )).first[0] as bool;

      final defaults = _defaults(m);
      String column(EntityField f) {
        final def = defaults[f.name];
        final pk = f.name == m.pk;
        final d = (!pk && def != null) ? ' NOT NULL DEFAULT ${_sqlLiteral(def)}' : '';
        return '"${f.name}" ${_type(f.type, pk: pk)}$d';
      }

      if (!exists) {
        final columns = m.fields.map(column).join(', ');
        final uniqueClause = m.unique
            .map((u) => ', UNIQUE (${u.map((k) => '"$k"').join(', ')})')
            .join();
        if (mode == 'validate') {
          mismatches.add('missing table ${m.table}');
          continue;
        }
        await c.execute('CREATE TABLE "${m.table}" ($columns$uniqueClause)');
        stdout.writeln('  + table ${m.table} (${m.fields.length} columns)');
        await _indexes(m, c, mode);
        if (mode != 'validate') await _createPartialIndexes(m, c);
        continue;
      }

      // the table exists — check for missing columns
      final hasColumns = (await c.execute(
        Sql.named('SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name=@t'),
        parameters: {'t': m.table},
      )).map((r) => r[0] as String).toSet();

      for (final f in m.fields.where((f) => !hasColumns.contains(f.name))) {
        if (mode == 'validate') {
          mismatches.add('${m.table}: missing column ${f.name}');
          continue;
        }
        await c.execute('ALTER TABLE "${m.table}" ADD COLUMN ${column(f)}');
        stdout.writeln('  + column ${m.table}.${f.name}');
      }

      // A UNIQUE added to the class AFTER the table was created would not appear by itself —
      // and without it ON CONFLICT has nothing to attach to and the write fails
      // only in production. We add missing ones; differing ones are not dropped,
      // because automatically removing constraints is the shortest road to duplicates.
      final hasUniques = (await c.execute(
        Sql.named('''SELECT pg_get_constraintdef(oid) FROM pg_constraint
                     WHERE contype='u' AND conrelid = @t::regclass'''),
        parameters: {'t': '"${m.table}"'},
      )).map((r) => r[0] as String).toSet();

      for (final u in m.unique) {
        final def = 'UNIQUE (${u.join(', ')})';
        if (hasUniques.any((d) => d.replaceAll('"', '') == def)) continue;
        if (mode == 'validate') {
          mismatches.add('${m.table}: missing constraint $def');
          continue;
        }
        try {
          await c.execute('ALTER TABLE "${m.table}" ADD '
              'UNIQUE (${u.map((k) => '"$k"').join(', ')})');
          stdout.writeln('  + unikat ${m.table} $def');
        } catch (e) {
          // the data already breaks the new constraint — a decision for a human
          stdout.writeln('  ! ${m.table}: cannot add $def — $e');
        }
      }

      await _indexes(m, c, mode);

      // columns in the database that are not in the class — only reported
      final orphaned = hasColumns.difference(m.fields.map((f) => f.name).toSet());
      if (orphaned.isNotEmpty) {
        stdout.writeln('  ! ${m.table}: columns without a class field: '
            '${orphaned.join(', ')} (kept — drop them by hand if unneeded)');
      }
    }

    // RLS after all tables: the policies of grant tables reach into `users` and `packages`
    for (final name in EntityRegistry.names) {
      await _rls(EntityRegistry.byName(name), c, mode);
    }

    if (mismatches.isNotEmpty) {
      stderr.writeln('IGNIS_SCHEMA=validate — the schema does not match the classes:');
      for (final r in mismatches) {
        stderr.writeln('  • $r');
      }
      exit(1);
    }
  }
}
