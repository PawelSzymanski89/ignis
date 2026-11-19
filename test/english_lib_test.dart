// HARD-L.10: runtime messages and comments in lib/ are in English. Allowed exceptions: the schema
// migration map (migration.dart), the transliteration table (permissions_page.dart), the audit-log
// secret-name fragments, and the constants 'ignis/podpis/v1' / 'totp-nowy|…' (changing them breaks data).
import 'dart:io';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

final _polish = RegExp(
    r'[ąćęłńóśźżĄĆĘŁŃÓŚŹŻ„]|\b(dozwolone|polityki|oczekiwane|indeks|unikat|zwolnienie|blokad|Ciasteczko|wymaga|'
    r'Platforma|Grosze|Logowanie|Konfiguracja|wymagane|wielu|kluczy|poleceniem|lista|Dane|sesji|sesja|sprzed|epoki|'
    r'zalogowanego|Adnotacja|Pakiety|kont|zapytaniem|Przyjmuje|strefy|czasowe|harmonogramy|wylogowanie|obcy|obrazek|'
    r'skasuj|ciasteczko|panelu|wszystkich|stron|Kod|odpowiedzi|Surowe|bajty|omija|ustawia|reszta|Pojedyncze|'
    r'nadpisanie|pomocnicze|globalne)\b');

bool _allowed(String path, String line) =>
    path.endsWith('engine/migration.dart') ||
    line.contains("'ignis/podpis/v1'") ||
    line.contains("'totp-nowy|") ||
    (path.endsWith('pages/permissions_page.dart') && line.contains('const accented')) ||
    (path.endsWith('engine/audit_log.dart') && line.contains("'haslo', 'sekret'"));

void main() {
  final hits = <String>[];
  for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
    final lines = f.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      if (_polish.hasMatch(lines[i]) && !_allowed(f.path, lines[i])) hits.add('${f.path}:${i + 1}: ${lines[i].trim()}');
    }
  }
  hits.forEach(print);
  check('no Polish in lib/ outside the allowed exceptions', hits.isEmpty);
  check('no leftover Caddy-specific comment in page_engine.dart',
      !File('lib/engine/page_engine.dart').readAsStringSync().contains('Caddy'));
  check('no empty _partialIndexes in schema.dart', !File('lib/engine/schema.dart').readAsStringSync().contains('_partialIndexes'));
}
