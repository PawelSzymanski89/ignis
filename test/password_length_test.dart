// Hasło > 72 bajtów UTF-8 — czytelny błąd walidacji, nigdy wyjątek bcrypt (audyt A#4).
import 'package:bcrypt/bcrypt.dart';

import '../lib/engine/db.dart';
import '../lib/engine/customer_accounts.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  final boundaryCases = 'a' * 72, tooMany = 'a' * 73, polish = 'ą' * 37; // 74 bajty, 37 znaków
  check('72 bajty przechodzą', !Db.passwordTooLong(boundaryCases));
  check('73 bajty za długie', Db.passwordTooLong(tooMany));
  check('liczą się bajty UTF-8, nie znaki', Db.passwordTooLong(polish));

  try {
    Db.hashPassword(tooMany);
    check('hashPassword odrzuca', false);
  } on FormatException catch (e) {
    check('hashPassword: FormatException z komunikatem o długości', e.message == Db.passwordLengthMessage);
  }
  check('hashPassword 72 bajtów działa', BCrypt.checkpw(boundaryCases, Db.hashPassword(boundaryCases)));

  check('logowanie panelu: za długie = null przed bazą', await Db.checkLogin('admin', tooMany) == null);

  final hash = BCrypt.hashpw(boundaryCases, BCrypt.gensalt());
  check('logowanie klienta: za długie = zwykły brak dopasowania', CustomerAccounts.passwordMatches(tooMany, hash) == false);
  check('zakładanie konta klienta: komunikat o długości', CustomerAccounts.passwordError(tooMany) == Db.passwordLengthMessage);
  check('poprawne hasło klienta bez błędu', CustomerAccounts.passwordError('poprawne-haslo') == null);

  // SEC-A-17: koszt 12 i jedna reguła hasła
  check('nowy hash ma koszt ${Db.bcryptCost}', Db.hashPassword('poprawne-haslo').startsWith('\$2a\$${Db.bcryptCost}\$'));
  check('hash kosztu 10 = do przeliczenia, 12 nie',
      Db.weakHash(BCrypt.hashpw('x', BCrypt.gensalt(logRounds: 10))) && !Db.weakHash(Db.hashPassword('poprawne-haslo')));
  check('ta sama reguła dla panelu i klientów (min. 10 znaków)',
      Db.passwordError('123456789') != null && Db.passwordError('1234567890') == null &&
          CustomerAccounts.passwordError('123456789') == Db.passwordError('123456789'));
}
