// ============================================================================
//  totp_test.dart — drugi składnik logowania na wektorach z RFC 6238
// ----------------------------------------------------------------------------
//  Własna implementacja TOTP ma jeden sposób weryfikacji: kody z załącznika B
//  do RFC. Jeśli się zgadzają, aplikacja uwierzytelniająca użytkownika też się
//  zgodzi — a jeśli nie, nikt się nie zaloguje i dowiemy się o tym najgorszą drogą.
// ============================================================================

import 'dart:convert';
import 'dart:typed_data';

import 'package:ignis/engine/totp.dart';

var errors = 0;
void check(String description, bool ok) {
  print('  ${ok ? "ok" : "BŁĄD"} — $description');
  if (!ok) errors++;
}

void main() {
  // RFC 6238, załącznik B: sekret ASCII "12345678901234567890", SHA-1
  final secret = Totp.encode(Uint8List.fromList(ascii.encode('12345678901234567890')));
  check('base32 sekretu z RFC', secret == 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ');
  check('dekodowanie odwraca kodowanie',
      ascii.decode(Totp.decode(secret)!) == '12345678901234567890');
  check('spacje i małe litery w sekrecie nie przeszkadzają',
      Totp.decode('gezd gnbv gy3t qojq gezd gnbv gy3t qojq') != null);
  check('śmieci odrzucone', Totp.decode('nie-jest-base32!!') == null);

  print('kody z RFC 6238 (SHA-1, 6 cyfr):');
  // (czas w sekundach, oczekiwany kod) — tablica z RFC, ostatnie 6 cyfr
  for (final (t, expected) in [
    (59, '287082'), (1111111109, '081804'), (1111111111, '050471'),
    (1234567890, '005924'), (2000000000, '279037'), (20000000000, '353130'),
  ]) {
    final k = Totp.code(secret, now: DateTime.fromMillisecondsSinceEpoch(t * 1000, isUtc: true));
    check('t=$t → $expected', k == expected);
  }

  print('weryfikacja:');
  final now = DateTime.utc(2026, 9, 3, 12, 0, 0);
  final current = Totp.code(secret, now: now)!;
  check('bieżący kod przechodzi', Totp.matches(secret, current, now: now));
  check('spacje w przepisanym kodzie nie przeszkadzają',
      Totp.matches(secret, '${current.substring(0, 3)} ${current.substring(3)}', now: now));
  // zegar telefonu potrafi się rozjechać — jeden krok w każdą stronę wybaczamy
  check('kod sprzed 30 s przechodzi',
      Totp.matches(secret, current, now: now.add(const Duration(seconds: 30))));
  check('kod sprzed 90 s NIE przechodzi',
      !Totp.matches(secret, current, now: now.add(const Duration(seconds: 90))));
  check('zły kod nie przechodzi', !Totp.matches(secret, '000000', now: now));
  check('pusty kod nie przechodzi', !Totp.matches(secret, '', now: now));
  check('kod o złej długości nie przechodzi', !Totp.matches(secret, '12345', now: now));
  check('nie-cyfry nie przechodzą', !Totp.matches(secret, 'abcdef', now: now));

  print('sekrety:');
  final a = Totp.newSecret(), b = Totp.newSecret();
  check('nowy sekret ma 32 znaki base32', a.length == 32);
  check('dwa sekrety się różnią', a != b);
  check('adres otpauth zawiera sekret i wydawcę',
      Totp.address(a, 'admin@firma.pl', 'C-CMS').contains('secret=$a'));
  check('czytelny sekret w grupach po cztery',
      Totp.readable('ABCDEFGH') == 'ABCD EFGH');

  print(errors == 0 ? 'WSZYSTKO OK' : 'BŁĘDÓW: $errors');
  if (errors > 0) throw StateError('$errors');
}
