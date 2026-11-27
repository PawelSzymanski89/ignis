// IGNIS-053.6: PageRegistry.build() warns (log, not an exception) about AdminPage routes without `requires` — any
// signed-in panel account of any package can open them. No database.
// Run: dart run test/admin_requires_warning_test.dart
import 'dart:io';

import 'package:ignis/ignis.dart';
import 'package:ignis/ignis_registry.g.dart';

import 'registry_helper.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

class OpenAdmin extends AdminPage {}

class GuardedAdmin extends AdminPage {}

class PlainPage extends PageEngine {}

List<String> build(IgnisRegistry r) {
  final lines = <String>[];
  IOOverrides.runZoned(() => PageRegistry.build(r), stdout: () => _Collector(lines), stderr: () => _Collector(lines));
  return lines;
}

void main() {
  final lines = build(testRegistry(pages: [
    testPage(const Page('/admin/open-x'), OpenAdmin.new, cookieAuth: true, adminPage: true),
    testPage(const Page('/admin/guarded-x', requires: 'x.view'), GuardedAdmin.new, cookieAuth: true, adminPage: true),
    testPage(const Page('/plain-x'), PlainPage.new),
  ]));
  final w = lines.where((l) => l.contains('requires')).join('\n');
  check('an AdminPage without requires → a start-up warning naming the route', w.contains('/admin/open-x (OpenAdmin)'));
  check('…not the AdminPage with requires', !w.contains('/admin/guarded-x'));
  check('…not a plain PageEngine page', !w.contains('/plain-x'));
  check('no warning when every AdminPage has requires', build(IgnisRegistry(entities: const [], pages: [
    testPage(const Page('/admin/guarded-x', requires: 'x.view'), GuardedAdmin.new, cookieAuth: true, adminPage: true),
  ])).every((l) => !l.contains('requires')));

  final core = build(ignisRegistry).where((l) => l.contains('requires')).join('\n');
  print('  core registry: $core');
  check('core: /admin/account (deliberately without requires) is listed', core.contains('/admin/account (AccountPage)'));
  print('\nALL PASSED');
}

class _Collector implements Stdout {
  _Collector(this.lines);
  final List<String> lines;
  @override
  void writeln([Object? o = '']) => lines.add('$o');
  @override
  dynamic noSuchMethod(Invocation i) => null;
}
