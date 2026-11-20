// ============================================================================
//  meta.dart — generated registry metadata (the shape the engine runs on)
// ----------------------------------------------------------------------------
//  These types hold EVERYTHING the engine needs about @Entity and @Page classes
//  as plain code: constructors are tear-offs (`ClassName.new`), fields are
//  getter/setter closures. Filled only by lib/ignis_registry.g.dart (the registry builder).
//
//  No SQL / tenant / RLS / auth / template logic lives here — only the data the
//  registries (orm.dart EntityRegistry, registry.dart PageRegistry) consume.
// ============================================================================

import 'annotations.dart';
import 'session.dart' show Sessions;

/// One entity field (column): its name, static type and get/set closures.
///
/// The closures are untyped on purpose (Object instance, Object? value): a
/// `List<FieldMeta>` cannot carry per-field generics without covariance grief, and
/// the engine only ever reads/writes `Object?` here anyway.
class FieldMeta {
  final String name;

  /// Dart field type (e.g. `int`, `String`, `DateTime`) — for DDL and (de)serialization.
  /// Nullability is erased (`int?` → `int`).
  final Type type;

  /// Reads the field off an instance.
  final Object? Function(Object) get;

  /// Writes the field on an instance.
  final void Function(Object, Object?) set;

  /// The field initializer as a value — becomes the column DEFAULT in auto-schema.
  /// Only CONST initializers (`String realm = 'staff'`); anything else is null
  /// (the registry builder prints a warning).
  final Object? defaultValue;

  const FieldMeta(this.name, this.type, this.get, this.set, {this.defaultValue});
}

/// Entity description: table, primary key, fields, @Cached and @Entity(unique:).
class EntityMeta {
  /// Simple class name (e.g. `User`) — the Redis cache / lock key uses it.
  final String typeName;

  /// URI of the declaring library (e.g. `package:ignis/entities/auth.dart`) — for start-up diagnostics.
  final String library;

  /// The Dart [Type] of the entity class — registry lookup key for `byType<T>`.
  final Type type;
  final String table;
  final String pk;
  final List<FieldMeta> fields;
  final bool cached;

  /// Lifetime of the Redis copy in seconds (from @Cached(ttl:)); 0 = no expiry.
  final int ttl;

  /// UNIQUE constraints (from @Entity(unique:)) — used by auto-schema.
  final List<List<String>> unique;

  /// Builds a fresh instance (`ClassName.new`) — hydrate/defaults.
  final Object Function() ctor;

  const EntityMeta({
    required this.typeName,
    required this.library,
    required this.type,
    required this.table,
    required this.pk,
    required this.fields,
    required this.cached,
    required this.ttl,
    required this.unique,
    required this.ctor,
  });

  /// Fields without the primary key (for INSERT/UPDATE).
  Iterable<FieldMeta> get nonId => fields.where((f) => f.name != pk);
}

/// Description of a field marked @Synced / @SessionSynced (for hydrate/persist from Redis).
class SyncedField {
  final String name; // field name
  final bool isSession; // true = @SessionSynced (per-user, session TTL); false = @Synced (global)
  final Type type; // field type (bool/int/double/String) — for (de)serialization
  SyncedField(this.name, this.isSession, this.type);

  /// Redis key. Global: synced:<Class>.<field>; session: ssync:<sha256(token)>:<Class>.<field> (outside sess:).
  String redisKey(String cls, String? token) =>
      isSession ? 'ssync:${Sessions.hashToken(token!)}:$cls.$name' : 'synced:$cls.$name';
}

/// A @Synced / @SessionSynced field, with closures to move it in and out of Redis.
class SyncedMeta extends SyncedField {
  final Object? Function(Object) get;
  final void Function(Object, Object?) set;
  SyncedMeta(super.name, super.isSession, super.type, this.get, this.set);
}

/// Page description: route metadata (@Page), constructor, @Action methods and synced fields.
class PageMeta {
  /// Simple class name (e.g. `LoginPage`) — used in @Page(api/cors) refusal messages.
  final String typeName;

  /// URI of the declaring library — for start-up diagnostics.
  final String library;

  /// The @Page annotation (route/template/redirect/requires/…).
  final Page page;

  /// Builds a fresh page instance per request (`ClassName.new`).
  final Object Function() ctor;

  /// @Action methods: action name → closures invoking that method on an instance.
  /// A method shared by base classes / overridden counts once (order preserved).
  final Map<String, List<Object? Function(Object)>> actions;

  /// @Synced / @SessionSynced fields of this class.
  final List<SyncedMeta> synced;

  /// Whether the page extends AdminPage or CustomerPage (cookie auth) — replaces the
  /// old `isSubclassOf` checks in registry/engine.
  final bool cookieAuth;

  /// Whether the page extends AdminPage — the multipart live-session gate in engine.dart.
  final bool adminPage;

  const PageMeta({
    required this.typeName,
    required this.library,
    required this.page,
    required this.ctor,
    required this.actions,
    required this.synced,
    required this.cookieAuth,
    required this.adminPage,
  });
}

/// The whole registry: every @Entity and @Page of the generated program, produced by the registry builder.
class IgnisRegistry {
  final List<EntityMeta> entities;
  final List<PageMeta> pages;

  /// Template attribute getters per class (`{{ obj.field }}`, generated): runtime type →
  /// (public getter name → read closure). The renderer uses these in JIT and AOT alike (render.dart).
  /// Empty for hand-built registries (tests) — then `{{ obj.field }}` on such objects renders empty.
  final Map<Type, Map<String, Object? Function(Object)>> attributes;

  /// Staleness fingerprint ([Fingerprint]) of the lib/ sources this registry was generated from, or null
  /// (hand-built registries / merges). Checked at JIT start-up (registry_fingerprint.dart).
  final Fingerprint? fingerprint;

  const IgnisRegistry({
    required this.entities,
    required this.pages,
    this.attributes = const {},
    this.fingerprint,
  });

  /// Merges [other] into this registry (e.g. the Ignis core registry + the app's). A class present in both
  /// (same library and name) is taken once, from [other]. The merged registry keeps the app's [fingerprint]
  /// (the one the start-up staleness check verifies) and the union of attribute getters.
  IgnisRegistry merge(IgnisRegistry other) {
    final e = {
      for (final m in [...entities, ...other.entities]) '${m.library}#${m.typeName}': m
    };
    final p = {
      for (final m in [...pages, ...other.pages]) '${m.library}#${m.typeName}': m
    };
    return IgnisRegistry(
      entities: e.values.toList(),
      pages: p.values.toList(),
      attributes: {...attributes, ...other.attributes},
      fingerprint: other.fingerprint,
    );
  }
}

/// A content fingerprint of a package's annotated-source tree, written into the generated registry so a JIT
/// start can notice a stale lib/ignis_registry.g.dart. [sum] is a sha256 over the sorted source files; [sources]
/// are their package-relative paths (e.g. `lib/entities/auth.dart`) under [package], so the start-up check can
/// re-read them through the package config (JIT only — an AOT binary has no sources and skips the check).
class Fingerprint {
  final String package;
  final List<String> sources;
  final String sum;
  const Fingerprint({required this.package, required this.sources, required this.sum});
}

/// The non-null static type of a field, from a getter closure: `ignisFieldType((User o) => o.id)` is `int` for
/// `int? id`. Generated code uses it so it never has to spell (and import) type names; nullability is erased.
Type ignisFieldType<C, V>(V? Function(C) getter) => V;
