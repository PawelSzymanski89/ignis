// Parity: the generated lib/ignis_registry.g.dart describes every core @Entity / @Page exactly as the
// dart:mirrors scan does (table, pk, fields + types, defaults, @Page, actions, synced, auth flags). Bez bazy.
import 'package:ignis/engine/mirrors_scan.dart';
import 'package:ignis/engine/registry_check.dart';
import 'package:ignis/ignis.dart';
import 'package:ignis/ignis_registry.g.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  final all = scanWithMirrors()!;
  // only the package's own lib/ (this test file declares no @Entity / @Page)
  bool core(String uri) => uri.startsWith('package:ignis/');
  final scanned = IgnisRegistry(
    entities: [
      for (final e in all.entities)
        if (core(e.library)) e
    ],
    pages: [
      for (final p in all.pages)
        if (core(p.library)) p
    ],
  );
  final diff = registryDifferences(ignisRegistry, scanned);
  for (final d in diff) {
    print('    $d');
  }
  check('generated registry == mirrors scan (${scanned.entities.length} entities, ${scanned.pages.length} pages)',
      diff.isEmpty);
  check('every core entity and page is there', ignisRegistry.entities.length == 12 && ignisRegistry.pages.length == 11);

  // the closures do what mirrors did: same defaults off a fresh instance, set/get round-trip
  final byName = {for (final e in scanned.entities) e.typeName: e};
  for (final g in ignisRegistry.entities) {
    final m = byName[g.typeName]!;
    final fresh = g.ctor();
    check(
        '${g.typeName}: fresh instance and defaults as in mirrors',
        fresh.runtimeType == g.type &&
            g.fields.every((f) => f.get(fresh) == m.fields.firstWhere((x) => x.name == f.name).get(m.ctor())) &&
            g.fields.every((f) => f.defaultValue == m.fields.firstWhere((x) => x.name == f.name).defaultValue));
  }
  final user = User();
  final username = ignisRegistry.entities.firstWhere((e) => e.typeName == 'User').fields.first;
  username.set(user, 'ala');
  check('setter/getter closures write and read the field', user.username == 'ala' && username.get(user) == 'ala');

  final routes = {for (final p in ignisRegistry.pages) p.page.route: p};
  check('page constructor builds the right class', routes['/admin/login']!.ctor() is LoginPage);
  check('AdminPage flag without mirrors', routes['/admin']!.adminPage && !routes['/health']!.adminPage);

  final wrongRoute = IgnisRegistry(entities: scanned.entities, pages: [
    for (final p in scanned.pages)
      p.typeName == 'HealthPage'
          ? PageMeta(
              typeName: p.typeName,
              library: p.library,
              page: const Page('/health-old', technical: true, noDb: true),
              ctor: p.ctor,
              actions: p.actions,
              synced: p.synced,
              cookieAuth: p.cookieAuth,
              adminPage: p.adminPage)
          : p
  ]);
  final stale = registryDifferences(wrongRoute, scanned, bothWays: false);
  check('a changed @Page is reported',
      stale.length == 1 && stale.single.contains('HealthPage') && stale.single.contains('/health-old'));
  final missing =
      registryDifferences(IgnisRegistry(entities: scanned.entities, pages: const []), scanned, bothWays: false);
  check('pages missing from the generated registry are reported', missing.length == 11);
  check('one-way check ignores classes only in the generated registry',
      registryDifferences(ignisRegistry, const IgnisRegistry(entities: [], pages: []), bothWays: false).isEmpty);
}
