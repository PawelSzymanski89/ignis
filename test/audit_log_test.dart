// ============================================================================
//  audit_log_test.dart — co wolno, a czego NIE WOLNO zapisać w dzienniku
// ----------------------------------------------------------------------------
//  Audyt zapisuje parametry każdej akcji panelu, więc jeden nieprzefiltrowany
//  wzorzec zamienia go w drugą kopię haseł i tokenów. To jest ten test.
// ============================================================================

import 'package:ignis/engine/audit_log.dart';
import 'package:ignis/engine/ignis.dart';
import 'package:ignis/engine/config.dart';

var errors = 0;
void check(String description, bool ok) {
  print('  ${ok ? "ok" : "BŁĄD"} — $description');
  if (!ok) errors++;
}

void main() {
  print('filtr sekretów:');
  for (final field in [
    'password', 'new_password', 'old', 'api_token_devel', 'dns_app_secret',
    'smtp_password', 'smtp_pass', 'firebase_key', 'tls_cert_prod', 'stripe_key', 'pin',
    // pola formularza zmiany hasła — ten wiersz wyszedł z realnego przecieku:
    // „old” does not contain „password” and used to slip through the filter
    'old_password', 'new_password', 'repeat_password', 'old', 'new', 'repeat', 'new_pw',
    // włączanie TOTP: sekret i kod z aplikacji (audyt A#8)
    'secret', 'code', 'signing_secret', 'key', 'token',
  ]) {
    check('$field nie trafia do dziennika',
        !AuditLog.describe({field: 'WARTOSC-SEKRETNA'}).contains('WARTOSC-SEKRETNA'));
  }

  print('co zostaje:');
  final description = AuditLog.describe({
    'triggerAction': 'save', 'csrf': 'tok', '__ip': '1.2.3.4',
    'id': '7', 'name': 'Demo Sp. Test', 'plan': 'biznes', 'puste': '',
    'code_postal': '00-001', 'news': 'tak',
  });
  check('id, nazwa i plan zostają',
      description.contains('id=7') && description.contains('Demo') && description.contains('plan=biznes'));
  check('code_postal to nie kod TOTP, news to nie new_', description.contains('code_postal=00-001') && description.contains('news=tak'));
  check('pola techniczne pomijane',
      !description.contains('csrf') && !description.contains('triggerAction') && !description.contains('__ip'));
  check('puste pola pomijane', !description.contains('puste'));

  print('rozmiar:');
  check('długa wartość ucinana', AuditLog.describe({'x': 'a' * 300}).length < 100);
  check('cały opis ma limit', AuditLog.describe({
        for (var i = 0; i < 50; i++) 'pole$i': 'wartosc$i',
      }).length <= 520);

  print('wielkość liter nie ratuje sekretu:');
  check('PASSWORD tak samo jak password', !AuditLog.describe({'PASSWORD': 'x1'}).contains('x1'));
  check('Api_Token tak samo', !AuditLog.describe({'Api_Token': 'x2'}).contains('x2'));

  print('ustawienia po Pole.sekret, nie po nazwie (SEC-B-4):');
  Ignis.settingsSections = const [
    Section('integracje', 'Integracje', 'fe fe-x', '', [
      Field('smtp_dsn', 'SMTP', type: FieldType.password),
      Field('credentials', 'Plik', type: FieldType.file),
      Field('adres', 'Adres'),
    ]),
  ];
  final u = AuditLog.describe({'p_smtp_dsn': 'smtp://u:SEKRET1@h', 'p_credentials': 'SEKRET2', 'p_adres': 'jawny'});
  check('pole haslo/plik ukryte mimo neutralnej nazwy', !u.contains('SEKRET1') && !u.contains('SEKRET2'));
  check('zwykłe pole ustawień zostaje', u.contains('p_adres=jawny'));
  check('ten sam predykat dla echa formularza (pin, key, code)',
      AuditLog.secret('pin') && AuditLog.secret('key') && AuditLog.secret('code') && AuditLog.secret('kod') && AuditLog.secret('p_smtp_dsn'));

  print(errors == 0 ? 'WSZYSTKO OK' : 'BŁĘDÓW: $errors');
  if (errors > 0) throw StateError('$errors');
}
