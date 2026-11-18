// FIX-14: htmx nie trzyma migawek panelu w localStorage — wyłączona pamięć historii w layoucie panelu,
// a stare migawki znikają na każdej stronie panelu i logowania (motyw.js ładowany w obu layoutach).
import 'dart:io';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  final layout = File('templates/_layout.html').readAsStringSync();
  final config = RegExp(r'''<meta name="htmx-config" content='([^']*)'>''').firstMatch(layout);
  check('layout panelu: htmx-config z historyCacheSize 0 i refreshOnHistoryMiss',
      config != null && config[1]!.contains('"historyCacheSize":0') && config[1]!.contains('"refreshOnHistoryMiss":true'));
  check('…przed htmx.min.js (htmx czyta konfigurację przy starcie)',
      layout.indexOf('name="htmx-config"') < layout.indexOf('htmx.min.js'));
  check('motyw.js usuwa htmx-history-cache',
      File('web/ignis/theme.js').readAsStringSync().contains("removeItem('htmx-history-cache')"));
  for (final l in ['templates/_layout.html', 'templates/_layout_bare.html']) {
    check('$l ładuje motyw.js', File(l).readAsStringSync().contains('/assets/ignis/theme.js'));
  }
}
