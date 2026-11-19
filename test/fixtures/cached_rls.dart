// Helper for test/cached_test.dart: @Cached on an RLS-scoped table without a service column
// (user_packages) — the registry must refuse it.
import 'package:ignis/engine/annotations.dart';
import 'package:ignis/engine/orm.dart';

@Entity('user_packages')
@Cached()
class CachedUserPackage {
  int? id;
  String username = '';
  String package_id = '';
}

void main() {
  final registry = IgnisRegistry(pages: const [], entities: [
    EntityMeta(
      typeName: 'CachedUserPackage',
      library: 'test',
      type: CachedUserPackage,
      table: 'user_packages',
      pk: 'id',
      cached: true,
      ttl: 0,
      unique: const [],
      ctor: CachedUserPackage.new,
      fields: [
        FieldMeta('id', int, (o) => (o as CachedUserPackage).id, (o, v) => (o as CachedUserPackage).id = v as int?),
        FieldMeta('username', String, (o) => (o as CachedUserPackage).username,
            (o, v) => (o as CachedUserPackage).username = v as String, defaultValue: ''),
        FieldMeta('package_id', String, (o) => (o as CachedUserPackage).package_id,
            (o, v) => (o as CachedUserPackage).package_id = v as String, defaultValue: ''),
      ],
    )
  ]);
  try {
    EntityRegistry.build(registry);
    print('REGISTERED');
  } on StateError catch (e) {
    print('REFUSED: $e');
  }
}
