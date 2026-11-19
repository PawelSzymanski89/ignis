// Pomocnik test/cached_test.dart: encja @Cached z kolumną usluga — rejestr musi ją odrzucić.
import 'package:ignis/engine/annotations.dart';
import 'package:ignis/engine/orm.dart';

@Entity('test_cached')
@Cached()
class TestCached {
  int? id;
  int service = 0;
}

void main() {
  final registry = IgnisRegistry(pages: const [], entities: [
    EntityMeta(
      typeName: 'TestCached',
      library: 'test',
      type: TestCached,
      table: 'test_cached',
      pk: 'id',
      cached: true,
      ttl: 0,
      unique: const [],
      ctor: TestCached.new,
      fields: [
        FieldMeta('id', int, (o) => (o as TestCached).id, (o, v) => (o as TestCached).id = v as int?),
        FieldMeta('service', int, (o) => (o as TestCached).service, (o, v) => (o as TestCached).service = v as int,
            defaultValue: 0),
      ],
    )
  ]);
  try {
    EntityRegistry.build(registry);
    print('ZAREJESTROWANA');
  } on StateError catch (e) {
    print('ODRZUCONA: $e');
  }
}
