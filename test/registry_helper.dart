// Test helper: build an IgnisRegistry for a test's own @Page / @Entity classes (the generator only scans lib/,
// so test classes are registered here by hand) merged with the core `ignisRegistry`. Replaces what the
// reflection scan used to do at start-up. `core` re-exports the generated registry for tests that need only it.
import 'package:ignis/ignis.dart';
import 'package:ignis/ignis_registry.g.dart';

/// The core (library) registry — pages and entities of package:ignis.
final IgnisRegistry core = ignisRegistry;

/// Core registry + the test's [pages] / [entities].
IgnisRegistry testRegistry({List<PageMeta> pages = const [], List<EntityMeta> entities = const []}) =>
    core.merge(IgnisRegistry(pages: pages, entities: entities));

/// PageMeta for a test page [ctor] carrying its [page] annotation (type name taken from a fresh instance).
PageMeta testPage(
  Page page,
  Object Function() ctor, {
  bool cookieAuth = false,
  bool adminPage = false,
  Map<String, List<Object? Function(Object)>> actions = const {},
  List<SyncedMeta> synced = const [],
}) =>
    PageMeta(
      typeName: ctor().runtimeType.toString(),
      library: 'test',
      page: page,
      ctor: ctor,
      actions: actions,
      synced: synced,
      cookieAuth: cookieAuth,
      adminPage: adminPage,
    );

/// EntityMeta for a test entity [ctor] with its [entity] annotation and [fields].
EntityMeta testEntity(
  Entity entity,
  Type type,
  Object Function() ctor,
  List<FieldMeta> fields, {
  bool cached = false,
  int ttl = 0,
}) =>
    EntityMeta(
      typeName: ctor().runtimeType.toString(),
      library: 'test',
      type: type,
      table: entity.table,
      pk: entity.pk,
      unique: entity.unique,
      cached: cached,
      ttl: ttl,
      ctor: ctor,
      fields: fields,
    );
