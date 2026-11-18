// ============================================================================
//  registry.dart — route registry built by REFLECTION (dart:mirrors)
// ----------------------------------------------------------------------------
//  The heart of "natural reflection": at startup we scan ALL loaded
//  libraries, look for classes annotated with @Page that extend PageEngine
//  and build a route -> (ClassMirror + @Page metadata) map.
//
//  ⚠️ The class must be REACHABLE (imported somewhere in the program, here in
//     lib/pages.dart). The Dart VM does not load code nothing refers to —
//     then mirrors will not see it.
//
//  Reflection is expensive, so we do it ONCE at startup (build()) and then
//  work on the ready map.
// ============================================================================

import 'dart:mirrors';

import 'annotations.dart';
import 'page_engine.dart';
import 'session.dart' show Sessions;

/// Description of a field marked @Synced / @SessionSynced (for hydrate/persist from Redis).
class SyncedField {
  final String name;      // field name
  final bool isSession;   // true = @SessionSynced (per-user, TTL sesji); false = @Synced (globalne)
  final Type type;        // field type (bool/int/double/String) — for (de)serialization
  SyncedField(this.name, this.isSession, this.type);

  /// Redis key. Global: synced:<Class>.<field>; session: ssync:<sha256(token)>:<Class>.<field> (outside sess:).
  String redisKey(String cls, String? token) =>
      isSession ? 'ssync:${Sessions.hashToken(token!)}:$cls.$name' : 'synced:$cls.$name';
}

/// One registry entry: how to build the page, its @Page metadata and synced fields.
class PageRoute {
  /// Mirror of the page class — used to create an instance per request.
  final ClassMirror classMirror;

  /// Adnotacja @Page (route/template/redirect/requires).
  final Page meta;

  /// @Synced / @SessionSynced fields of this class (detected once, at startup).
  final List<SyncedField> syncedFields;

  /// @Action methods: action name → list of method symbols (run before insertData).
  final Map<String, List<Symbol>> actions;

  PageRoute(this.classMirror, this.meta, this.syncedFields, this.actions);

  /// Creates a fresh page instance (new per request — no shared state).
  /// Assumes a no-arg constructor in the page class.
  PageEngine newInstance() =>
      classMirror.newInstance(const Symbol(''), const []).reflectee as PageEngine;
}

/// Global route registry. Filled once by build().
class PageRegistry {
  static final Map<String, PageRoute> _routes = {};

  /// Returns the route for a path or null (404). An exact path wins; then routes
  /// with `{name}` segments (e.g. `/v1/profiles/{id}`), which match one non-empty segment.
  static PageRoute? match(String path) {
    final r = _routes[path];
    if (r != null) return r;
    for (final w in _withParams) {
      if (pathParams(w.meta.route, path) != null) return w;
    }
    return null;
  }

  // computed once in build() — match/underApi are on the path of every request
  static List<PageRoute> _withParams = const [];
  static Set<String> _apiPrefixes = const {};

  /// Values of the `{name}` segments of route [pattern] for [path] (decoded from %XX), or null when it does not match.
  static Map<String, String>? pathParams(String pattern, String path) {
    final w = pattern.split('/'), p = path.split('/');
    if (w.length != p.length) return null;
    final result = <String, String>{};
    for (var i = 0; i < w.length; i++) {
      final s = w[i];
      if (s.length > 2 && s.startsWith('{') && s.endsWith('}')) {
        if (p[i].isEmpty) return null;
        final String v;
        try {
          v = Uri.decodeComponent(p[i]);
        } on ArgumentError {
          return null;
        }
        result[s.substring(1, s.length - 1)] = v;
      } else if (s != p[i]) {
        return null;
      }
    }
    return result;
  }


  /// Whether [path] lies under the prefix of `api: true` pages (first segment, e.g. `/v1/`)
  /// or is such a page — the API client then gets errors as JSON, not HTML.
  static bool underApi(String path) {
    if (_routes[path]?.meta.api ?? false) return true;
    final seg = path.split('/');
    return seg.length > 2 && _apiPrefixes.contains(seg[1]);
  }

  /// List of registered paths (for startup logs).
  static Iterable<String> get routes => _routes.keys;

  /// Menu items visible for the given permissions. The filter is EXACTLY the same
  /// as in AdminPage.isAbleToSee — the user will not see an item they cannot enter anyway.
  static List<Map<String, String>> menu(bool Function(String?) allows,
      {bool platform = false}) {
    final pos = _routes.values
        .where((r) =>
            r.meta.label != null &&
            (platform || !r.meta.platformOnly) &&
            allows(r.meta.requires))
        .toList()
      ..sort((a, b) => a.meta.order.compareTo(b.meta.order));
    return [
      for (final r in pos)
        {
          'route': r.meta.route,
          'label': r.meta.label!,
          'icon': r.meta.icon ?? 'fe fe-circle',
          'group': r.meta.group ?? '',
        }
    ];
  }

  /// The same menu, cut into sections in order of appearance. Grouping is done
  /// HERE, not in the template: jinja 0.6.7 has no loop variables, so comparing
  /// "did the group change" would need tricks that are hard to read.
  static List<Map<String, Object>> menuSections(bool Function(String?) allows,
      {bool platform = false}) {
    final sections = <String, List<Map<String, String>>>{};
    for (final p in menu(allows, platform: platform)) {
      sections.putIfAbsent(p['group'] ?? '', () => []).add(p);
    }
    return [
      for (final e in sections.entries)
        {'name': e.key, 'items': e.value}
    ];
  }

  /// Reflective scan: walk libraries → classes → find @Page.
  /// Called once, at server startup (bin/server.dart).
  static void build() {
    _routes.clear();
    final mirrors = currentMirrorSystem();
    // the base type pages MUST extend
    final pageEngineType = reflectClass(PageEngine);

    for (final lib in mirrors.libraries.values) {
      for (final decl in lib.declarations.values) {
        if (decl is! ClassMirror) continue;
        // the page must extend PageEngine
        if (!decl.isSubclassOf(pageEngineType)) continue;

        // we look for @Page metadata on the class
        for (final meta in decl.metadata) {
          final r = meta.reflectee;
          if (r is Page) {
            _routes[r.route] = PageRoute(decl, r, _scanSynced(decl), scanActions(decl));
            break; // one @Page per class
          }
        }
      }
    }
    _withParams = [for (final r in _routes.values) if (r.meta.route.contains('{')) r];
    _apiPrefixes = {
      for (final r in _routes.values)
        if (r.meta.api && r.meta.route.split('/').length > 2) r.meta.route.split('/')[1]
    };
  }

  /// Scan of the class fields annotated with @Synced / @SessionSynced (once, at startup).
  static List<SyncedField> _scanSynced(ClassMirror cls) {
    final out = <SyncedField>[];
    for (final d in cls.declarations.values) {
      if (d is! VariableMirror || d.isStatic) continue;
      for (final m in d.metadata) {
        final r = m.reflectee;
        if (r is SyncedMarker || r is SessionSyncedMarker) {
          out.add(SyncedField(
            MirrorSystem.getName(d.simpleName),
            r is SessionSyncedMarker,
            d.type.reflectedType,
          ));
          break;
        }
      }
    }
    return out;
  }

  /// Scan of the class methods annotated with @Action → name → [method Symbol] map.
  /// Also from the page's base classes (actions shared by several pages); a method overridden in a subclass counts once.
  static Map<String, List<Symbol>> scanActions(ClassMirror cls) {
    final out = <String, List<Symbol>>{};
    final seen = <Symbol>{};
    final pageEngine = reflectClass(PageEngine);
    for (ClassMirror? c = cls; c != null && c != pageEngine; c = c.superclass) {
      for (final d in c.declarations.values) {
        if (d is! MethodMirror || !d.isRegularMethod || d.isStatic || !seen.add(d.simpleName)) continue;
        for (final m in d.metadata) {
          final r = m.reflectee;
          if (r is Action) {
            (out[r.name] ??= <Symbol>[]).add(d.simpleName);
            break;
          }
        }
      }
    }
    return out;
  }
}
