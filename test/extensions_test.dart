// Uprawnienia i sekcje ustawień dokładane przez aplikację — bez bazy i bez serwera.
// Uruchomienie: dart test/extensions_test.dart   (asercje, zero frameworka)
import 'package:ignis/ignis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  final core = Seed.catalog.length;
  check('rdzeń ustawień to tylko „Ogólne”', configSections.map((s) => s.id).toList().join() == 'general');

  Ignis.permissions = const [('demo.view', 'Podgląd demo')];
  Ignis.settingsSections = const [
    Section('demo', 'Demo', 'fe fe-box', 'Ustawienia demo.', [
      Field('demo_token', 'Token', type: FieldType.password),
      Field('demo_limit', 'Limit', type: FieldType.number, defaultValue: '3'),
    ]),
    Section('plat', 'Platforma', 'fe fe-box', '', [Field('plat_json', 'JSON', type: FieldType.file)],
        platformOnly: true),
  ];

  check('uprawnienie aplikacji w katalogu', Seed.catalog.contains(('demo.view', 'Podgląd demo')));
  check('katalog = rdzeń + 1', Seed.catalog.length == core + 1);
  check('sekcja aplikacji w konfiguracji', configSections.any((s) => s.id == 'demo'));
  check('sekret aplikacji w kluczeSekretne', secretKeys.contains('demo_token'));
  check('domyślna aplikacji w domyslneUstawienia', defaultSettings['demo_limit'] == '3');

  check('poleUstawien: pole usługi', settingField('demo_token', platform: false)?.type == FieldType.password);
  check('poleUstawien: sekcja platformy niewidoczna z usługi', settingField('plat_json', platform: false) == null);
  check('poleUstawien: sekcja platformy z platformy', settingField('plat_json', platform: true)?.type == FieldType.file);
  check('poleUstawien: nieznany klucz', settingField('cokolwiek', platform: true) == null);
}
