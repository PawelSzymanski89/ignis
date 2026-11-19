// KontaKlientow: każde otwarcie sesji zapisuje ostatnie_logowanie (SQL bez bazy), kolumna z encji User.
import 'package:ignis/ignis.dart';
import 'package:ignis/ignis_registry.g.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  EntityRegistry.build(ignisRegistry);
  final s = CustomerAccounts.accountSessionSql;
  check('pierwsze logowanie zakłada konto z czasem', s.contains("VALUES (@u, '', 'customer', @s, @n)"));
  check('kolejne logowanie aktualizuje tylko czas (hasło i realm nietknięte)',
      s.contains('DO UPDATE SET last_login = EXCLUDED.last_login') && !s.contains('pass_hash =') && !s.contains('realm ='));
  check('kolumna w encji users (auto-schema), domyślnie 0 = nigdy',
      EntityRegistry.byType(User).fields.any((f) => f.name == 'last_login') && User().last_login == 0);
}
