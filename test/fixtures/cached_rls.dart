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
  try {
    EntityRegistry.build();
    print('REGISTERED');
  } on StateError catch (e) {
    print('REFUSED: $e');
  }
}
