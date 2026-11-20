// Ignis.resolveRegistry (Ignis.start): no registry → StateError with the exact commands; a registry → core + app;
// a fingerprint that no longer matches lib/ → ONE warning (build/watch commands) and the start goes on; no sources
// on disk (as in AOT) → the check is skipped. Bez bazy.
import 'dart:io';

import 'package:ignis/engine/registry_fingerprint.dart';
import 'package:ignis/ignis.dart';
import 'package:ignis/ignis_registry.g.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

@Page('/test-start-app')
class StartAppPage extends PageEngine {}

PageMeta _appPage() => PageMeta(
    typeName: 'StartAppPage',
    library: 'test',
    page: const Page('/test-start-app'),
    ctor: StartAppPage.new,
    actions: const {},
    synced: const [],
    cookieAuth: false,
    adminPage: false);

void main() {
  print('no registry:');
  Object? error;
  try {
    Ignis.resolveRegistry(null);
  } catch (e) {
    error = e;
  }
  final m = '$error';
  check('StateError', error is StateError);
  check('…with the exact steps: dev_dependencies, build / watch, registry: line',
      m.contains('dev_dependencies:  build_runner   (the only one') &&
          m.contains('build_runner') &&
          m.contains('dart run build_runner build') &&
          m.contains('dart run build_runner watch') &&
          m.contains('registry: ignisRegistry'));
  check('no removed build_runner flag in the message', !m.contains('--delete-conflicting-outputs'));

  print('registry:');
  final warnings = <String>[];
  final merged = Ignis.resolveRegistry(IgnisRegistry(entities: const [], pages: [_appPage()]), warn: warnings.add);
  check('core + app, no warning without a fingerprint',
      warnings.isEmpty && merged.pages.length == ignisRegistry.pages.length + 1);
  check('core attribute getters kept in the merge', merged.attributes.containsKey(User));
  PageRegistry.build(merged);
  check('app and core routes', PageRegistry.match('/test-start-app') != null && PageRegistry.match('/admin') != null);

  print('fingerprint (JIT):');
  final pkg = Directory.systemTemp.createTempSync('ignis_fp_');
  Directory('${pkg.path}/lib/src').createSync(recursive: true);
  File('${pkg.path}/lib/app.dart').writeAsStringSync('class A {}\n');
  File('${pkg.path}/lib/src/b.dart').writeAsStringSync('class B {}\n');
  File('${pkg.path}/lib/ignis_registry.g.dart').writeAsStringSync('// generated, not part of the sum\n');
  final sources = librarySources(pkg);
  check('sources: sorted lib/**.dart without the generated file',
      sources.join(',') == 'lib/app.dart,lib/src/b.dart');
  final fp = Fingerprint(
      package: 'app', sources: sources, sum: fingerprintSum(sources, (p) => File('${pkg.path}/$p').readAsStringSync()));
  check('current sources → no warning', staleRegistryWarning(fp, root: pkg) == null);
  File('${pkg.path}/lib/ignis_registry.g.dart').writeAsStringSync('// regenerated\n');
  check('the generated file itself does not count', staleRegistryWarning(fp, root: pkg) == null);
  File('${pkg.path}/lib/src/b.dart').writeAsStringSync('class B { int x = 1; }\n');
  final edited = staleRegistryWarning(fp, root: pkg);
  check('an edited file → one line naming build and watch',
      edited != null &&
          !edited.contains('\n') &&
          edited.contains('dart run build_runner build`') &&
          edited.contains('dart run build_runner watch') &&
          !edited.contains('--delete-conflicting-outputs'));
  File('${pkg.path}/lib/c.dart').writeAsStringSync('class C {}\n');
  check('an added file → reported as added', staleRegistryWarning(fp, root: pkg)!.contains('1 added'));

  print('resolveRegistry with a stale fingerprint:');
  warnings.clear();
  final stale = Fingerprint(package: 'ignis', sources: ignisRegistry.fingerprint!.sources, sum: '0' * 64);
  final started = Ignis.resolveRegistry(
      IgnisRegistry(entities: const [], pages: [_appPage()], fingerprint: stale),
      warn: warnings.add);
  check('exactly one warning, and the start goes on with the registry as it is',
      warnings.length == 1 && warnings.single.contains('out of date') && started.pages.any((p) => p.typeName == 'StartAppPage'));

  print('no sources (AOT):');
  check('a package not in the package config → check skipped',
      staleRegistryWarning(Fingerprint(package: 'no_such_package_xyz', sources: const [], sum: '0' * 64)) == null);
  check('no fingerprint → nothing to check', staleRegistryWarning(null) == null);
  pkg.deleteSync(recursive: true);
}
