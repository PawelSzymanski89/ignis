// Ignis.resolveRegistry (Ignis.start): without a registry → mirrors scan + one warning line (JIT); with the
// generated one → core + app, compared with mirrors; a stale one stops the start with the build command. Bez bazy.
import 'package:ignis/ignis.dart';
import 'package:ignis/ignis_registry.g.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

@Page('/test-start-app')
class StartAppPage extends PageEngine {}

@Entity('test_start_notes')
class StartNote {
  int? id;
  String text = '';
}

PageMeta _appPage(String route) => PageMeta(
    typeName: 'StartAppPage',
    library: Uri.base.resolve('test/registry_start_test.dart').toString(),
    page: Page(route),
    ctor: StartAppPage.new,
    actions: const {},
    synced: const [],
    cookieAuth: false,
    adminPage: false);

EntityMeta _appEntity() => EntityMeta(
    typeName: 'StartNote',
    library: Uri.base.resolve('test/registry_start_test.dart').toString(),
    type: StartNote,
    table: 'test_start_notes',
    pk: 'id',
    cached: false,
    ttl: 0,
    unique: const [],
    ctor: StartNote.new,
    fields: [
      FieldMeta('id', int, (o) => (o as StartNote).id, (o, v) => (o as StartNote).id = v as int?),
      FieldMeta('text', String, (o) => (o as StartNote).text, (o, v) => (o as StartNote).text = v as String,
          defaultValue: ''),
    ]);

void main() {
  final warnings = <String>[];
  final legacy = Ignis.resolveRegistry(null, warn: warnings.add);
  check('no registry (JIT): mirrors scan finds app and core pages',
      legacy.pages.any((p) => p.page.route == '/test-start-app') && legacy.pages.any((p) => p.page.route == '/admin'));
  check('no registry: exactly one warning line with the command',
      warnings.length == 1 && !warnings.single.contains('\n') && warnings.single.contains(buildCommand));

  final app = IgnisRegistry(entities: [_appEntity()], pages: [_appPage('/test-start-app')]);
  warnings.clear();
  final merged = Ignis.resolveRegistry(app, warn: warnings.add);
  check(
      'generated registry: core + app, no warning',
      warnings.isEmpty &&
          merged.pages.length == ignisRegistry.pages.length + 1 &&
          merged.entities.length == ignisRegistry.entities.length + 1);
  PageRegistry.build(merged);
  EntityRegistry.build(merged);
  check('routes and entities come from it',
      PageRegistry.match('/test-start-app') != null && EntityRegistry.byType(StartNote).table == 'test_start_notes');

  Object? error;
  try {
    Ignis.resolveRegistry(IgnisRegistry(entities: [_appEntity()], pages: [_appPage('/test-start-old')]));
  } catch (e) {
    error = e;
  }
  check(
      'a changed @Page in the code → the start is refused with the class and the command',
      error is StateError &&
          '$error'.contains('StartAppPage') &&
          '$error'.contains('/test-start-old') &&
          '$error'.contains(buildCommand));

  error = null;
  try {
    Ignis.resolveRegistry(IgnisRegistry(entities: const [], pages: [_appPage('/test-start-app')]));
  } catch (e) {
    error = e;
  }
  check('an @Entity added after the last build → refused, named as missing',
      error is StateError && '$error'.contains('StartNote') && '$error'.contains('missing'));
}
