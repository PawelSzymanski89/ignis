// Test logowania kont frontu hasłem — część bez bazy: hash, walidacja, login konta.
import 'dart:isolate';

import 'package:bcrypt/bcrypt.dart';

import '../lib/engine/db.dart';
import '../lib/engine/customer_accounts.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  final h = BCrypt.hashpw('dobre-haslo-123', BCrypt.gensalt(logRounds: 4));
  check('poprawne hasło pasuje', CustomerAccounts.passwordMatches('dobre-haslo-123', h));
  check('złe hasło nie pasuje', !CustomerAccounts.passwordMatches('zle-haslo-1234', h));
  check('konto bez hasła (link/SSO) nie loguje się hasłem i nie rzuca',
      !CustomerAccounts.passwordMatches('nie-ma-takiego-konta', ''));
  check('hasło < 10 znaków odrzucone', CustomerAccounts.passwordError('krotkie') != null);
  check('hasło 10 znaków przyjęte', CustomerAccounts.passwordError('0123456789') == null);
  check('login konta: usługa + e-mail małymi literami',
      CustomerAccounts.accountLogin(3, ' Ala@Firma.PL ') == 'c:3:ala@firma.pl');
  check('komunikaty logowania jako stałe (front tłumaczy po wartości)',
      CustomerAccounts.passwordMessage.isNotEmpty && CustomerAccounts.limitMessage != CustomerAccounts.passwordMessage);
  final k = CustomerAccounts.resetKey('ab' * 24);
  check('reset: w Redisie skrót tokenu, nie token', k.startsWith('creset:') && !k.contains('ab' * 24) && k.length == 7 + 64 &&
      CustomerAccounts.resetKey('ab' * 24) == k && CustomerAccounts.resetKey('cd' * 24) != k);
  check('reset: odcisk hasła zmienia się ze zmianą hasła, pusty hash (konto bez hasła) też ma odcisk',
      CustomerAccounts.passwordFingerprint(h) != CustomerAccounts.passwordFingerprint(BCrypt.hashpw('inne-haslo-123', BCrypt.gensalt(logRounds: 4))) &&
          CustomerAccounts.passwordFingerprint('').length == 16 && !CustomerAccounts.passwordFingerprint(h).contains(h.substring(7, 20)));
  // SEC-A-10: e-mail bez kwadratowych nawrotów i z limitem długości
  final sw = Stopwatch()..start();
  final bad = CustomerAccounts.validEmail('a@${'.' * 200000}@');
  check('a@ + 200 000 kropek: odrzucony szybko (${sw.elapsedMilliseconds} ms)', !bad && sw.elapsedMilliseconds < 200);
  sw.reset();
  check('a@b + 50 000 × ".c" + "@" odrzucony szybko', !CustomerAccounts.validEmail('a@b${'.c' * 50000}@') && sw.elapsedMilliseconds < 200);
  check('poprawne adresy przechodzą',
      CustomerAccounts.validEmail('ala@firma.pl') && CustomerAccounts.validEmail('a.b+x@sub.firma.co.uk'));
  check('zła składnia odpada', !CustomerAccounts.validEmail('a@b') && !CustomerAccounts.validEmail('a@.pl') &&
      !CustomerAccounts.validEmail('a@b..pl') && !CustomerAccounts.validEmail('a@b.pl.'));
  check('ponad 254 znaki odpada', !CustomerAccounts.validEmail('${'a' * 250}@b.pl'));

  // FIX-12: atrapa to stała — konto bez hasła w świeżym izolacie to JEDEN bcrypt, jak konto z hasłem
  check('atrapa: koszt ${Db.bcryptCost}, poprawny hash',
      Db.emptyHash.startsWith('\$2a\$${Db.bcryptCost}\$') && BCrypt.checkpw('nie-ma-takiego-konta', Db.emptyHash));
  final real = BCrypt.hashpw('dobre-haslo-123', BCrypt.gensalt(logRounds: Db.bcryptCost));
  Future<int> elapsed(String hash) async {
    final sw = Stopwatch()..start();
    await Isolate.run(() => CustomerAccounts.passwordMatches('zle-haslo-1234', hash));
    return sw.elapsedMicroseconds;
  }
  await elapsed(real); // rozgrzewka
  final withPassword = await elapsed(real), noPassword = await elapsed('');
  check('konto bez hasła nie trwa dłużej niż z hasłem (${noPassword ~/ 1000} vs ${withPassword ~/ 1000} ms)',
      noPassword < withPassword * 1.5);
}
