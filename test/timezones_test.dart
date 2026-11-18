import 'dart:io';

import 'package:ignis/engine/timezones.dart';

var _errors = 0;
void check(String description, bool w) {
  if (!w) _errors++;
  print('  ${w ? 'ok' : 'FAIL'} — $description');
}

int utc(int r, int m, int d, int h, [int mi = 0]) => DateTime.utc(r, m, d, h, mi).millisecondsSinceEpoch;

void main() {
  check('znane strefy', knownZone('Europe/Warsaw') && knownZone('UTC') && knownZone('America/New_York'));
  check('nieznana strefa', !knownZone('Europe/Gdansk') && !knownZone(''));
  check('lista stref zawiera Asia/Tokyo', zoneNames().contains('Asia/Tokyo'));
  check('Warszawa zimą +60, latem +120', offsetMin('Europe/Warsaw', utc(2026, 1, 10, 12)) == 60 &&
      offsetMin('Europe/Warsaw', utc(2026, 7, 10, 12)) == 120);
  check('10:00 w Warszawie 15.11 = 09:00 UTC', instantInZone('Europe/Warsaw', 2026, 11, 15, 10, 0) == utc(2026, 11, 15, 9));
  check('10:00 w Warszawie 15.07 = 08:00 UTC', instantInZone('Europe/Warsaw', 2026, 7, 15, 10, 0) == utc(2026, 7, 15, 8));
  check('9:00 w Nowym Jorku 15.11 = 14:00 UTC', instantInZone('America/New_York', 2026, 11, 15, 9, 0) == utc(2026, 11, 15, 14));
  // 29.03.2026 02:00 → 03:00 w Warszawie: 02:30 nie istnieje → przesunięcie o godzinę dziury (01:30 UTC = 03:30 CEST)
  check('wiosenna dziura 02:30 → 03:30 lokalnie', instantInZone('Europe/Warsaw', 2026, 3, 29, 2, 30) == utc(2026, 3, 29, 1, 30));
  // 25.10.2026 03:00 → 02:00: 02:30 dwa razy → pierwsze (00:30 UTC, jeszcze CEST)
  check('jesienna dwuznaczność 02:30 → pierwsze wystąpienie', instantInZone('Europe/Warsaw', 2026, 10, 25, 2, 30) == utc(2026, 10, 25, 0, 30));
  final s = wallInZone('Asia/Tokyo', utc(2026, 11, 15, 20));
  check('ściana w Tokio: 16.11 05:00, poniedziałek', s.day == 16 && s.hour == 5 && s.weekday == 1);

  const daily = Recurring(10, 0);
  check('codziennie 10:00: przed 10 → dziś', daily.next('Europe/Warsaw', utc(2026, 11, 15, 8)) == utc(2026, 11, 15, 9));
  check('codziennie 10:00: dokładnie 10 → jutro (ściśle po)',
      daily.next('Europe/Warsaw', utc(2026, 11, 15, 9)) == utc(2026, 11, 16, 9));
  check('codziennie przez zmianę czasu: 24.10 10:00 CEST → 25.10 10:00 CET',
      daily.next('Europe/Warsaw', utc(2026, 10, 24, 8)) == utc(2026, 10, 25, 9));
  const monWed = Recurring(18, 30, weekdays: {1, 3});
  // 15.11.2026 to niedziela
  check('pon i śr 18:30: z niedzieli → poniedziałek 16.11', monWed.next('Europe/Warsaw', utc(2026, 11, 15, 12)) == utc(2026, 11, 16, 17, 30));
  check('pon i śr 18:30: z poniedziałku po 18:30 → środa 18.11',
      monWed.next('Europe/Warsaw', utc(2026, 11, 16, 18)) == utc(2026, 11, 18, 17, 30));

  check('kraj → strefa: PL, pl (małe), JP, DE (Berlin/Büsingen ten sam czas)',
      countryZone('PL') == 'Europe/Warsaw' && countryZone('pl') == 'Europe/Warsaw' && countryZone('JP') == 'Asia/Tokyo' &&
          countryZone('DE') == 'Europe/Berlin');
  check('kraje o kilku czasach i nieznane → null (US, BR, RU, AU, ES, XX, puste)',
      ['US', 'BR', 'RU', 'AU', 'ES', 'XX', ''].every((k) => countryZone(k) == null));
  check('każda strefa z mapy krajów jest znana', countryZones.values.every(knownZone) && countryZones.length > 200);
  check('strefaOdbiorcy: tz ma pierwszeństwo, zły tz → kraj, kraj wielostrefowy → domyślna',
      recipientZone(tz: 'America/Chicago', country: 'PL', defaultValue: 'UTC') == 'America/Chicago' &&
          recipientZone(tz: 'Mars/Olympus', country: 'PL', defaultValue: 'UTC') == 'Europe/Warsaw' &&
          recipientZone(country: 'US', defaultValue: 'Europe/Warsaw') == 'Europe/Warsaw' && recipientZone(defaultValue: 'UTC') == 'UTC');
  if (_errors > 0) print('NOT PASSED: $_errors');
  exit(_errors > 0 ? 1 : 0);
}
