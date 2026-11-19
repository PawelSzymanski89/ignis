// ============================================================================
//  registry_check.dart — does a generated registry match what the program declares?
// ----------------------------------------------------------------------------
//  Compares two IgnisRegistry values class by class (library URI + class name):
//  entity table/pk/@Cached/unique/fields (name, type, default), page @Page metadata,
//  actions, synced fields and the AdminPage/CustomerPage flags. Used by the parity
//  test and by Ignis.start in JIT (generated registry vs the dart:mirrors scan), so a
//  forgotten `dart run build_runner build` stops the node instead of serving
//  yesterday's routes.
// ============================================================================

import 'annotations.dart';
import 'meta.dart';

/// Human-readable differences between [generated] and [scanned]; empty = they match.
/// [bothWays] = false skips classes present only in [generated]: a class deleted or renamed in the code
/// already breaks compilation of the stale .g.dart, so at start-up such a class is merely one that mirrors
/// cannot see (not imported by the program) — not a sign of a stale registry.
List<String> registryDifferences(IgnisRegistry generated, IgnisRegistry scanned, {bool bothWays = true}) {
  final out = <String>[];
  void compare<T>(String kind, List<T> gen, List<T> scan, String Function(T) key, String Function(T) describe) {
    final g = {for (final x in gen) key(x): x};
    final s = {for (final x in scan) key(x): x};
    for (final k in (s.keys.toSet()..removeAll(g.keys)).toList()..sort()) {
      out.add('$kind $k: missing from the generated registry');
    }
    if (bothWays) {
      for (final k in (g.keys.toSet()..removeAll(s.keys)).toList()..sort()) {
        out.add('$kind $k: in the generated registry, but not in the code');
      }
    }
    for (final k in (g.keys.toSet()..retainAll(s.keys)).toList()..sort()) {
      final a = describe(g[k] as T), b = describe(s[k] as T);
      if (a != b) out.add('$kind $k: changed\n      generated: $a\n      code:      $b');
    }
  }

  compare('@Entity', generated.entities, scanned.entities, (e) => '${e.library}#${e.typeName}', describeEntity);
  // Column defaults: the generator keeps only CONST initializers (a non-const one is null, with a build
  // warning), while mirrors read any initializer off a fresh instance — so only a generated default is compared.
  final scannedByKey = {for (final e in scanned.entities) '${e.library}#${e.typeName}': e};
  for (final g in generated.entities) {
    final s = scannedByKey['${g.library}#${g.typeName}'];
    if (s == null) continue;
    for (final f in g.fields) {
      final m = s.fields.where((x) => x.name == f.name).firstOrNull;
      if (m != null && f.defaultValue != null && f.defaultValue != m.defaultValue) {
        out.add('@Entity ${g.library}#${g.typeName}: default of ${f.name} changed '
            '(generated ${_value(f.defaultValue)}, code ${_value(m.defaultValue)})');
      }
    }
  }
  compare('@Page', generated.pages, scanned.pages, (p) => '${p.library}#${p.typeName}', describePage);
  return out;
}

/// Stable one-line description of an entity — everything the engine reads from it except column defaults.
String describeEntity(EntityMeta e) => [
      'table=${e.table}',
      'pk=${e.pk}',
      'cached=${e.cached}',
      'ttl=${e.ttl}',
      'unique=${e.unique}',
      'fields=[${e.fields.map((f) => '${f.name}:${f.type}').join(', ')}]',
    ].join(' ');

/// Stable one-line description of a page — @Page, actions (name × count), synced fields and auth flags.
String describePage(PageMeta p) => [
      describeAnnotation(p.page),
      'actions={${(p.actions.keys.toList()..sort()).map((k) => '$k×${p.actions[k]!.length}').join(', ')}}',
      'synced=[${p.synced.map((f) => '${f.name}:${f.type}${f.isSession ? ' session' : ''}').join(', ')}]',
      'cookieAuth=${p.cookieAuth}',
      'adminPage=${p.adminPage}',
    ].join(' ');

/// Every field of a @Page annotation.
String describeAnnotation(Page p) => '@Page(${p.route}, template=${p.template}, '
    'redirect=${p.redirectIfNotAbleToSee}, requires=${p.requires}, label=${p.label}, icon=${p.icon}, '
    'order=${p.order}, group=${p.group}, platformOnly=${p.platformOnly}, technical=${p.technical}, '
    'noDb=${p.noDb}, exemptFromPasswordChange=${p.exemptFromPasswordChange}, api=${p.api}, '
    'methods=${p.methods}, maxBody=${p.maxBody}, binary=${p.binary}, cors=${p.cors})';

String _value(Object? v) => v is String ? "'$v'" : '$v';
