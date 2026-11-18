// Ustawienia w modelu szablonu — bez odszyfrowanych sekretów (audyt A#1, A#3).
import '../lib/engine/ignis.dart';
import '../lib/engine/config.dart';
import '../lib/engine/crypto.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  Ignis.settingsSections = const [
    Section('demo', 'Demo', 'fe fe-box', '', [
      Field('demo_klucz_tajny', 'Klucz tajny', type: FieldType.password),
      Field('demo_poswiadczenia', 'Poświadczenia', type: FieldType.file),
      Field('demo_klucz_publiczny', 'Klucz publiczny'),
    ]),
  ];
  final full = {
    for (final k in secretKeys) k: 'JAWNY-SEKRET',
    'site_name': 'Demo',
    'footer': 'stopka',
    'demo_klucz_publiczny': 'pk_test',
  };
  check('są sekrety do odfiltrowania',
      secretKeys.containsAll({'demo_klucz_tajny', 'demo_poswiadczenia'}));
  final model = Crypto.withoutSecrets(full);
  check('żaden sekret nie trafia do modelu', !model.values.contains('JAWNY-SEKRET'));
  check('ustawienia jawne zostają',
      model['site_name'] == 'Demo' && model['footer'] == 'stopka' && model['demo_klucz_publiczny'] == 'pk_test');
}
