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
  try {
    EntityRegistry.build();
    print('ZAREJESTROWANA');
  } on StateError catch (e) {
    print('ODRZUCONA: $e');
  }
}
