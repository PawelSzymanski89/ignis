// ============================================================================
//  registry.dart — route registry built from IgnisRegistry metadata
// ----------------------------------------------------------------------------
//  At startup Ignis hands over the generated [IgnisRegistry] (lib/ignis_registry.g.dart)
//  and we build a route -> (PageMeta + @Page) map once; requests then work on the ready map.
// ============================================================================

import 'annotations.dart';
import 'meta.dart';
import 'page_engine.dart';

export 'meta.dart';

/// One registry entry: how to build the page, its @Page metadata, synced fields and actions.
class PageRoute {
  /// Description of the page class (constructor, actions, synced fields).
  final PageMeta pageMeta;

  PageRoute(this.pageMeta);

  /// The @Page annotation (route/template/redirect/requires).
  Page get meta => pageMeta.page;

  /// @Synced / @SessionSynced fields of this class.
  List<SyncedMeta> get syncedFields => pageMeta.synced;

  /// @Action methods: action name → closures invoking them (run before insertData).
  Map<String, List<Object? Function(Object)>> get actions => pageMeta.actions;

  /// Creates a fresh page instance (new per request — no shared state).
  PageEngine newInstance() => pageMeta.ctor() as PageEngine;
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

  /// Builds the route table from the generated [registry]. Called once, at server startup (Ignis.start).
  static void build(IgnisRegistry registry) {
    final source = registry;
    _routes.clear();
    final refused = <String>[];
    for (final p in source.pages) {
      if ((p.page.api || p.page.cors) && p.cookieAuth) refused.add('${p.page.route} (${p.typeName})');
      _routes[p.page.route] = PageRoute(p);
    }
    if (refused.isNotEmpty) {
      throw StateError('@Page(api: true) / @Page(cors: true) skip CSRF, so they must not authenticate by cookie; '
          'these pages extend AdminPage or CustomerPage (session cookie): ${refused.join(', ')}. '
          'Extend PageEngine and authenticate by a token in a header, or drop api/cors and keep CSRF');
    }
    _withParams = [for (final r in _routes.values) if (r.meta.route.contains('{')) r];
    _apiPrefixes = {
      for (final r in _routes.values)
        if (r.meta.api && r.meta.route.split('/').length > 2) r.meta.route.split('/')[1]
    };
  }
}

/// Command that (re)generates the registry — quoted in every start-up message about it.
const buildCommand = 'dart run build_runner build';

/// Command that keeps the registry current during development (rebuilds after every save).
const watchCommand = 'dart run build_runner watch';

/// Start-up error when `Ignis.start(registry:)` is missing: the engine cannot import the app's pages/entities
/// by itself — the generated file does, so the app passes it.
const noRegistryError = 'Ignis: Ignis.start(registry:) is required — your pages and entities reach the engine '
    'through lib/ignis_registry.g.dart, generated by the builder that ships in ignis. To generate and pass it:\n'
    '  1. add to dev_dependencies:  build_runner   (the only one — the builder is part of ignis)\n'
    '  2. run:  $buildCommand   (or keep  $watchCommand  during development)\n'
    "  3. in your main:  import 'ignis_registry.g.dart';  and  Ignis.start(registry: ignisRegistry, …)";
