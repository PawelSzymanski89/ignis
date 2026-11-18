// format.dart: czas trwania w jednym kształcie (zegar) i nazwa kraju z kodu ISO w EN/PL.
import 'package:ignis/ignis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  check('czasTrwania: m:ss poniżej godziny', duration(46000) == '0:46' && duration(113000) == '1:53');
  check('czasTrwania: zero i ujemne → 0:00', duration(0) == '0:00' && duration(-5) == '0:00');
  check('czasTrwania: zaokrąglenie do sekundy', duration(46499) == '0:46' && duration(59500) == '1:00');
  check('czasTrwania: h:mm:ss od godziny', duration(3600000) == '1:00:00' && duration(3725000) == '1:02:05');
  check('nazwaKraju: PL i EN, wielkość liter kodu bez znaczenia',
      countryName('PL', 'pl') == 'Polska' && countryName('pl', 'en') == 'Poland');
  check('nazwaKraju: inny język → angielska, nieznany kod → null',
      countryName('DE', 'de') == 'Germany' && countryName('ZZ', 'pl') == null);
  check('krajZKodem: „Nazwa (KOD)”, nieznany zostaje kodem, pusty pusty',
      countryWithCode('GB', 'pl') == 'Wielka Brytania (GB)' && countryWithCode('US', 'en') == 'United States (US)' &&
          countryWithCode('ZZ', 'en') == 'ZZ' && countryWithCode('', 'en') == '');
  print('format_test: OK');
}
