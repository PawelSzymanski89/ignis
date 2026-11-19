// ============================================================================
//  mirrors_scan.dart — build an IgnisRegistry by REFLECTION (dart:mirrors)
// ----------------------------------------------------------------------------
//  The ONLY file in the engine that imports dart:mirrors. It is reached through a
//  conditional import (mirrors_scan_stub.dart in AOT), so `dart compile exe` never
//  pulls dart:mirrors in. In JIT it is the legacy fallback (no generated registry)
//  AND the staleness check: Ignis compares the generated registry against this scan
//  at startup and refuses to run on a stale lib/ignis_registry.g.dart.
//
//  ⚠️ Mirrors see only REACHABLE classes (imported somewhere in the program). That
//     is why the barrels must be imported. The generated registry has no such trap.
//
//  ponytail: remove this file, attribute_mirrors.dart and both conditional imports (registry.dart,
//  orm.dart, ignis.dart, render.dart) once Dart removes dart:mirrors (dart-lang/sdk#44489: deprecated in
//  3.14, "will be removed in a future release"); then Ignis.start(registry:) becomes required.
// ============================================================================

// deprecated since Dart 3.14 — the one place Ignis still imports it (JIT fallback + staleness check)
// ignore: deprecated_member_use
import 'dart:mirrors';

import 'admin_page.dart';
import 'annotations.dart';
import 'customer_page.dart';
import 'meta.dart';
import 'page_engine.dart';

/// Scans all loaded libraries for @Entity and @Page classes and returns the registry.
/// Returns a value only in JIT; the AOT stub returns null.
IgnisRegistry? scanWithMirrors() {
  final entities = <EntityMeta>[];
  final pages = <PageMeta>[];

  final pageEngine = reflectClass(PageEngine);
  final adminPage = reflectClass(AdminPage);
  final customerPage = reflectClass(CustomerPage);

  for (final lib in currentMirrorSystem().libraries.values) {
    for (final decl in lib.declarations.values) {
      if (decl is! ClassMirror) continue;

      Entity? entity;
      Cached? cached;
      Page? page;
      for (final m in decl.metadata) {
        final r = m.reflectee;
        if (r is Entity) entity = r;
        if (r is Cached) cached = r;
        if (r is Page) page = r;
      }

      if (entity != null) {
        entities.add(_entity(decl, entity, cached));
      }
      if (page != null && decl.isSubclassOf(pageEngine)) {
        pages.add(_page(decl, page, pageEngine, adminPage, customerPage));
      }
    }
  }
  return IgnisRegistry(entities: entities, pages: pages);
}

EntityMeta _entity(ClassMirror cm, Entity entity, Cached? cached) {
  final fields = <FieldMeta>[];
  // defaults from a FRESH instance (no no-arg constructor → no defaults)
  InstanceMirror? fresh;
  try {
    fresh = cm.newInstance(const Symbol(''), const []);
  } catch (_) {}
  for (final d in cm.declarations.values) {
    if (d is VariableMirror && !d.isStatic && !d.isPrivate) {
      final name = MirrorSystem.getName(d.simpleName);
      final sym = d.simpleName;
      fields.add(FieldMeta(
        name,
        d.type.reflectedType,
        (o) => reflect(o).getField(sym).reflectee,
        (o, v) => reflect(o).setField(sym, v),
        defaultValue: fresh?.getField(sym).reflectee,
      ));
    }
  }
  return EntityMeta(
    typeName: MirrorSystem.getName(cm.simpleName),
    library: (cm.owner as LibraryMirror).uri.toString(),
    type: cm.reflectedType,
    table: entity.table,
    pk: entity.pk,
    fields: fields,
    cached: cached != null,
    ttl: cached?.ttl ?? 0,
    unique: entity.unique,
    ctor: () => cm.newInstance(const Symbol(''), const []).reflectee as Object,
  );
}

PageMeta _page(ClassMirror cm, Page page, ClassMirror pageEngine, ClassMirror adminPage, ClassMirror customerPage) {
  final synced = <SyncedMeta>[];
  for (final d in cm.declarations.values) {
    if (d is! VariableMirror || d.isStatic || d.isPrivate) continue;
    for (final m in d.metadata) {
      final r = m.reflectee;
      if (r is SyncedMarker || r is SessionSyncedMarker) {
        final sym = d.simpleName;
        synced.add(SyncedMeta(
          MirrorSystem.getName(sym),
          r is SessionSyncedMarker,
          d.type.reflectedType,
          (o) => reflect(o).getField(sym).reflectee,
          (o, v) => reflect(o).setField(sym, v),
        ));
        break;
      }
    }
  }

  // @Action methods, also from base classes; an overridden method counts once.
  final actions = <String, List<Object? Function(Object)>>{};
  final seen = <Symbol>{};
  for (ClassMirror? c = cm; c != null && c != pageEngine; c = c.superclass) {
    for (final d in c.declarations.values) {
      if (d is! MethodMirror || !d.isRegularMethod || d.isStatic || !seen.add(d.simpleName)) continue;
      for (final m in d.metadata) {
        final r = m.reflectee;
        if (r is Action) {
          final sym = d.simpleName;
          (actions[r.name] ??= []).add((o) => reflect(o).invoke(sym, const []).reflectee);
          break;
        }
      }
    }
  }

  return PageMeta(
    typeName: MirrorSystem.getName(cm.simpleName),
    library: (cm.owner as LibraryMirror).uri.toString(),
    page: page,
    ctor: () => cm.newInstance(const Symbol(''), const []).reflectee as Object,
    actions: actions,
    synced: synced,
    cookieAuth: cm.isSubclassOf(adminPage) || cm.isSubclassOf(customerPage),
    adminPage: cm.isSubclassOf(adminPage),
  );
}
