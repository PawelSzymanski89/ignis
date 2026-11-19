// ============================================================================
//  orm.dart — annotation-driven ODM
// ----------------------------------------------------------------------------
//  @Entity on a plain class → field metadata (EntityMeta: generated registry, or the
//  dart:mirrors scan in JIT) → parameterized SQL.
//  API (from PageEngine): saveEntity, readEntity<T>(id), readEntitys<T>().
//  Primary key: @Entity(pk:) (`id` by default) — save/read/delete/insert/upsert use it.
//
//  - saving under a PER-ENTITY LOCK (Redis lock:<Type>:<id>) — no race between nodes;
//    unlock after the database write,
//  - @Cached → entity mirror in Redis (every node sees the same; read-through; a write invalidates it),
//  - SQL always parameterized (SQL injection closed at the source).
// ============================================================================

import 'dart:convert';

import 'package:postgres/postgres.dart' hide Type;

import 'db.dart';
import 'meta.dart';
import 'mirrors_scan_stub.dart' if (dart.library.mirrors) 'mirrors_scan.dart';
import 'registry.dart' show noRegistryError;
import 'redis.dart';
import 'crypto.dart';
import 'schema.dart';

export 'meta.dart';

/// Former name of [FieldMeta] (entity field / column).
typedef EntityField = FieldMeta;

/// Entity registry: Type → metadata. Built once (EntityRegistry.build()).
class EntityRegistry {
  static final Map<String, EntityMeta> _byName = {};

  /// Fills the registry from [registry]; without it (JIT only) from the dart:mirrors scan.
  static void build([IgnisRegistry? registry]) {
    final source = registry ?? scanWithMirrors();
    if (source == null) throw StateError(noRegistryError);
    _byName.clear();
    for (final meta in source.entities) {
      // the `entity:<Type>:<id>` mirror does not know the service, and Orm.read from the mirror bypasses RLS —
      // service A would read service B's row by id alone (SEC-A-5); any table under RLS, not only with `service`
      if (meta.cached && Schema.rlsScoped(meta)) {
        throw StateError('@Cached on an RLS-scoped entity (${meta.typeName}, table ${meta.table}) would bypass service isolation');
      }
      _byName[meta.typeName] = meta;
    }
  }

  static Iterable<String> get names => _byName.keys;
  static EntityMeta byType(Type t) => _byName[t.toString()]!;
  static EntityMeta byName(String n) => _byName[n]!;
  static EntityMeta byInstance(Object o) => _byName[o.runtimeType.toString()]!;
}

class Orm {
  static String _insertPrefix(EntityMeta m) {
    final cols = m.fields.map((f) => f.name);
    return 'INSERT INTO ${m.table} (${cols.join(',')}) '
        'VALUES (${cols.map((c) => '@$c').join(',')}) ON CONFLICT (${m.pk}) DO ';
  }

  /// SQL of [insert]: a duplicate primary key is skipped.
  static String insertSql(EntityMeta m) => '${_insertPrefix(m)}NOTHING';

  /// SQL of [upsert]: a duplicate primary key overwrites the other columns.
  static String upsertSql(EntityMeta m) =>
      '${_insertPrefix(m)}UPDATE SET ${m.nonId.map((f) => '${f.name}=EXCLUDED.${f.name}').join(',')}';

  /// SQL UPDATE in [save] (key parameter = PK column name).
  static String updateSql(EntityMeta m) =>
      'UPDATE ${m.table} SET ${m.nonId.map((f) => '${f.name}=@${f.name}').join(',')} '
      'WHERE ${m.pk}=@${m.pk}';

  /// Saves an entity (INSERT when the primary key is null — the database assigns it, otherwise UPDATE
  /// by key) under a per-entity lock. Keys assigned by the app: [insert]/[upsert].
  static Future<void> save(Object entity) async {
    final meta = EntityRegistry.byInstance(entity);
    final pk = meta.fields.firstWhere((f) => f.name == meta.pk);
    final id = pk.get(entity);
    final conn = await Db.connect();

    // field values (without id on INSERT)
    Map<String, Object?> values(Iterable<FieldMeta> fs) => {
          for (final f in fs) f.name: f.get(entity),
        };

    // PER-ENTITY lock (for an existing id). For a new one (INSERT) the database assigns the id.
    final lockKey = id == null ? null : 'lock:${meta.typeName}:$id';
    final owner = lockKey == null ? null : await lock(lockKey);
    try {
      if (id == null) {
        // INSERT ... RETURNING id
        final cols = meta.nonId.map((f) => f.name).toList();
        final sql = 'INSERT INTO ${meta.table} (${cols.join(',')}) '
            'VALUES (${cols.map((c) => '@$c').join(',')}) RETURNING ${meta.pk}';
        final res = await conn.execute(Sql.named(sql), parameters: values(meta.nonId));
        pk.set(entity, res.first[0]); // write the assigned id back
      } else {
        await conn.execute(Sql.named(updateSql(meta)), parameters: values(meta.fields));
      }
      if (meta.cached) await _invalidate(meta, pk.get(entity)!);
    } finally {
      if (owner != null) await unlock(lockKey!, owner);
    }
  }

  /// INSERT with an app-assigned primary key; a duplicate key is skipped.
  /// true = row added. No lock — a single query is atomic.
  static Future<bool> insert(Object entity) => _insertRow(entity, insertSql);

  /// INSERT or overwrite of the row with the same primary key.
  static Future<void> upsert(Object entity) => _insertRow(entity, upsertSql);

  static Future<bool> _insertRow(Object entity, String Function(EntityMeta) sql) async {
    final meta = EntityRegistry.byInstance(entity);
    final vals = {for (final f in meta.fields) f.name: f.get(entity)};
    final r = await (await Db.connect()).execute(Sql.named(sql(meta)), parameters: vals);
    if (r.affectedRows > 0 && meta.cached) await _invalidate(meta, vals[meta.pk]!);
    return r.affectedRows > 0;
  }

  /// Deletes an entity of type T by primary key (and its mirror when @Cached).
  static Future<void> delete<T>(Object id) async {
    final meta = EntityRegistry.byType(T);
    await (await Db.connect()).execute(
        Sql.named('DELETE FROM ${meta.table} WHERE ${meta.pk}=@id'), parameters: {'id': id});
    if (meta.cached) await _invalidate(meta, id);
  }

  /// Reads one entity of type T by primary key (from the cache when @Cached, otherwise from the database).
  /// A transaction that has written a @Cached entity reads the database and leaves the mirror alone.
  static Future<T?> read<T>(Object id) async {
    final meta = EntityRegistry.byType(T);
    final mirrored = meta.cached && !Db.hasCachedWrites;
    final key = 'entity:${meta.typeName}:$id';
    String? lease;
    if (mirrored) {
      final raw = await Redis.get(key);
      if (raw != null && !raw.startsWith(_lease)) {
        try {
          return _fromMirror(meta, raw) as T;
        } catch (_) {
          await Redis.del(key); // unreadable entry (older format, foreign write) = miss
        }
      }
      if (raw == null) {
        // the lease is taken BEFORE the database read: a write that commits in between drops it, so the fill below
        // cannot bring back the old row
        lease = '$_lease${Crypto.randomToken(8)}';
        if (!await Redis.setNxEx(key, lease, 10)) lease = null;
      }
    }
    final res = await (await Db.connect()).execute(
      Sql.named('SELECT * FROM ${meta.table} WHERE ${meta.pk}=@id'),
      parameters: {'id': id},
    );
    if (res.isEmpty) return null;
    final map = res.first.toColumnMap();
    if (lease != null) await _fill(meta, key, lease, map);
    return _hydrate(meta, map) as T;
  }

  /// Reads all entities of type T (v0: from the database).
  static Future<List<T>> readAll<T>() async {
    final meta = EntityRegistry.byType(T);
    final conn = await Db.connect();
    final res = await conn.execute('SELECT * FROM ${meta.table} ORDER BY ${meta.pk}');
    return res.map((row) => _hydrate(meta, row.toColumnMap()) as T).toList();
  }

  /// Entities of type T from any query with named parameters (`SELECT * FROM table WHERE …`).
  /// Columns matched by field name; fields without a column in the result keep their default value.
  static Future<List<T>> pick<T>(String sql, [Map<String, Object?> params = const {}]) async {
    final meta = EntityRegistry.byType(T);
    final res = await (await Db.connect()).execute(Sql.named(sql), parameters: params);
    return [for (final row in res) _hydrate(meta, row.toColumnMap()) as T];
  }

  // --- helpers ----------------------------------------------------------------

  /// Builds an entity instance from a column→value map (constructor + field setters).
  static Object _hydrate(EntityMeta meta, Map<String, dynamic> map) {
    final inst = meta.ctor();
    for (final f in meta.fields) {
      if (map.containsKey(f.name)) f.set(inst, map[f.name]);
    }
    return inst;
  }

  /// Prefix of a placeholder that a reader puts in the mirror before reading the database.
  static const _lease = 'lease:';

  /// A write invalidates the mirror (entity:<Type>:<id>) and never fills it: right away, so other nodes stop
  /// reading the old row, and again after the transaction ends (COMMIT or ROLLBACK), so a reader that filled
  /// it from the still committed old row in between does not keep it.
  static Future<void> _invalidate(EntityMeta meta, Object id) async {
    final key = 'entity:${meta.typeName}:$id';
    Db.noteCachedWrite();
    await Redis.del(key);
    await Db.afterTransaction(() => Redis.del(key));
  }

  /// Fills the mirror with a row read from the database — only if the key still holds this reader's [lease]
  /// (no write dropped it meanwhile). ttl from @Cached (0 = no expiry).
  static Future<void> _fill(EntityMeta meta, String key, String lease, Map<String, Object?> vals) async {
    final json = jsonEncode(vals.map((k, v) => MapEntry(k, v is DateTime ? v.toUtc().toIso8601String() : v)));
    await Redis.cmd([
      'EVAL',
      "if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end "
          "if ARGV[3] == '0' then redis.call('SET', KEYS[1], ARGV[2]) "
          "else redis.call('SET', KEYS[1], ARGV[2], 'EX', ARGV[3]) end return 1",
      '1',
      key,
      lease,
      json,
      '${meta.ttl}',
    ]);
  }

  static Object _fromMirror(EntityMeta meta, String json) {
    final raw = (jsonDecode(json) as Map).cast<String, dynamic>();
    for (final f in meta.fields) {
      if (raw[f.name] is String && f.type.toString().replaceAll('?', '') == 'DateTime') {
        raw[f.name] = DateTime.parse(raw[f.name] as String);
      }
    }
    return _hydrate(meta, raw);
  }

  /// Simple distributed lock: SET key val NX EX 5, with a short retry.
  /// Takes the lock with a random value; returns it (for release) or null after fail-open.
  static Future<String?> lock(String key) async {
    final value = Crypto.randomToken(16);
    for (var i = 0; i < 50; i++) {
      if (await Redis.setNxEx(key, value, 5)) return value;
      await Future.delayed(const Duration(milliseconds: 40));
    }
    // after ~2 s we give up (fail-open, so the request does not hang forever)
    return null;
  }

  /// Releases the lock only if it is still ours — after the TTL expires someone else holds it.
  static Future<void> unlock(String key, String value) async => Redis.cmd([
        'EVAL',
        "if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) end return 0",
        '1',
        key,
        value,
      ]);
}
