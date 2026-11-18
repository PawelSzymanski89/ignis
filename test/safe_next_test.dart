// KontaKlientow.bezpiecznyDalej: tylko ścieżka lokalna — bez `//`, `\`, TAB i znaków kontrolnych (bez bazy).
import 'package:ignis/engine/customer_accounts.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  String d(String? x) => CustomerAccounts.safeNext(x);
  check('ścieżka lokalna z query przechodzi', d('/app/x?a=1&b=%20') == '/app/x?a=1&b=%20');
  check('sam / przechodzi', d('/') == '/');
  for (final bad in ['//evil.example', '/\\evil.example', '/\t/evil.example', '/\n/evil', '/\r//evil', '/a\\b',
      'https://evil.example', 'evil', '', ' /x', '/x y', '/\x00x', '/\x7f']) {
    check('odrzucone: ${Uri.encodeComponent(bad)}', d(bad) == '/account');
  }
  check('null → domyślny', d(null) == '/account');
}
