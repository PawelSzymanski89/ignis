// SEC-A-8: ustawienia nie są wyrocznią deszyfrowania. Odszyfrowywane są tylko klucze sekretne, z AAD
// "usluga|klucz" — szyfrogram przeklejony do pola jawnego, innej usługi albo innego klucza zostaje nieczytelny.
// Uruchomienie: tool/pg_test.sh test/crypto_pg_test.dart
import 'dart:io';

import 'package:ignis/ignis.dart';
// ignore: unused_import
import 'package:ignis/entities.dart';
import 'package:ignis/ignis_registry.g.dart';
import 'package:postgres/postgres.dart' show Sql;
import 'pg_guard.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  if (skipDestructive()) return;
  EntityRegistry.build(ignisRegistry);
  await Schema.sync();
  Ignis.settingsSections = const [
    Section('test', 'Test', '', '', [Field('test.haslo', 'Hasło', type: FieldType.password)]),
  ];
  const secretField = 'test.haslo', plaintext = 'stopka';
  check('test.haslo jest sekretem, stopka nie', Crypto.isSecret(secretField) && !Crypto.isSecret(plaintext));

  check('v2 z kontekstem: tam-i-z-powrotem', Crypto.decrypt(Crypto.encrypt('tajne', context: 'a'), context: 'a') == 'tajne');
  check('v2 w innym kontekście — pusto', Crypto.decrypt(Crypto.encrypt('tajne', context: 'a'), context: 'b') == '');
  check('v1 (dane sprzed v2) dalej czytelne', Crypto.decrypt(Crypto.encrypt('stare')) == 'stare');

  late Map<String, String> withoutSecrets;
  final result = await Db.asSystem(() async {
    await Permissions.saveSetting(7, secretField, 'haslo-uslugi-7');
    final ciphertext = (await (await Db.connect()).execute(
            Sql.named('SELECT value FROM settings WHERE id=@i'), parameters: {'i': '$secretField@7'}))
        .first[0] as String;
    Object? error;
    try {
      await Permissions.saveSetting(8, plaintext, ciphertext);
    } on FormatException catch (e) {
      error = e;
    }
    // wklejka obejściem formularza (np. kopia bazy) — odczyt i tak nie deszyfruje pola jawnego
    await (await Db.connect()).execute(
        Sql.named("INSERT INTO settings (id, key, value, service) VALUES (@i, @k, @v, 8) "
            "ON CONFLICT (id) DO UPDATE SET value = EXCLUDED.value"),
        parameters: {'i': '$plaintext@8', 'k': plaintext, 'v': ciphertext});
    await (await Db.connect()).execute(
        Sql.named("INSERT INTO settings (id, key, value, service) VALUES (@i, @k, @v, 8) "
            "ON CONFLICT (id) DO UPDATE SET value = EXCLUDED.value"),
        parameters: {'i': '$secretField@8', 'k': secretField, 'v': ciphertext});
    await Redis.delMany(['settings:7', 'settings:8']);
    withoutSecrets = await Permissions.settings(7, secrets: false);
    return (ciphertext, error, await Permissions.settings(7), await Permissions.settings(8));
  });
  final (ciphertext, error, u7, u8) = result;
  check('sekret zapisany jako enc:v2', ciphertext.startsWith('enc:v2:'));
  check('właściciel czyta swój sekret', u7[secretField] == 'haslo-uslugi-7');
  check('zapis szyfrogramu w pole jawne odrzucony', error is FormatException);
  check('szyfrogram w polu jawnym nie jest odszyfrowywany', u8[plaintext] == ciphertext);
  check('szyfrogram usługi 7 w sekrecie usługi 8 — pusto (AAD)', u8[secretField] == '');
  await Db.close();
  check('ustawienia(sekrety: false) — bez kluczy sekretnych (do modelu szablonu, bez deszyfrowania)',
      !withoutSecrets.containsKey(secretField));
  print('\nALL PASSED');
  exit(0);
}
