// IGNIS-053.7: start-up warning when a `cors: true` route exists and Engine.preflightOrigin is null — the preflight
// then echoes every Origin and only the page's own allowOrigin call stands between a foreign site and the API.
// No database. Run: dart run test/cors_gate_warning_test.dart
import 'dart:io';

import 'package:ignis/ignis.dart';
import 'package:ignis/ignis_registry.g.dart';

import 'registry_helper.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

class CorsApi extends PageEngine {}

class PlainApi extends PageEngine {}

String build(IgnisRegistry r) {
  final lines = <String>[];
  IOOverrides.runZoned(() => PageRegistry.build(r), stdout: () => _Collector(lines), stderr: () => _Collector(lines));
  return lines.where((l) => l.contains('preflightOrigin')).join('\n');
}

void main() {
  final registry = testRegistry(pages: [
    testPage(const Page('/v1/cors-x', api: true, cors: true, methods: ['POST']), CorsApi.new),
    testPage(const Page('/v1/plain-x', api: true, methods: ['POST']), PlainApi.new),
  ]);
  final w = build(registry);
  check('cors: true route without Engine.preflightOrigin → start-up warning naming the route',
      w.contains('/v1/cors-x (CorsApi)'));
  check('…not the route without cors', !w.contains('/v1/plain-x'));
  Engine.preflightOrigin = (origin, uri) async => false;
  check('with Engine.preflightOrigin set → no warning', build(registry).isEmpty);
  Engine.preflightOrigin = null;
  check('no cors: true route (core registry) → no warning', build(ignisRegistry).isEmpty);
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
