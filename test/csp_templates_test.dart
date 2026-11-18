// Szablony pakietu pod CSP `script-src 'self'`: skrypty tylko z plików, bez on*=, javascript: i danych w JS.
import 'dart:io';

void check(String description, bool ok) {
  if (!ok) throw StateError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  final files = Directory('templates').listSync().whereType<File>().where((f) => f.path.endsWith('.html'));
  for (final f in files) {
    // komentarze Jinji nie trafiają do HTML-a
    final t = f.readAsStringSync().replaceAll(RegExp(r'\{#.*?#\}', dotAll: true), ''), n = f.uri.pathSegments.last;
    check('$n: brak inline <script>', !RegExp(r'<script(?![^>]*\bsrc=)[^>]*>').hasMatch(t));
    check('$n: brak atrybutów on*=', !RegExp(r'''\son[a-z]+\s*=\s*["']''').hasMatch(t));
    check('$n: brak javascript:', !t.contains('javascript:'));
  }
  for (final l in ['_layout.html', '_layout_bare.html']) {
    final t = File('templates/$l').readAsStringSync();
    check('$l: CSP meta from Engine.cspMeta', t.contains('content="{{ csp }}"'));
    check('$l: bez nieużywanych bibliotek motywu', !RegExp('choices|flatpickr|pickr|jsvectormap').hasMatch(t));
    check('$l: Popper tylko z bootstrap.bundle', !t.contains('popper.min.js') && t.contains('bootstrap.bundle.min.js'));
    for (final z in ['div', 'ul', 'li']) {
      check('$l: <$z> zbalansowane',
          RegExp('<$z[\\s>]').allMatches(t).length == RegExp('</$z>').allMatches(t).length);
    }
  }
  for (final f in Directory('web/ignis').listSync().whereType<File>().where((f) => f.path.endsWith('.js'))) {
    check('FIX-53: ${f.path} bez przypisań do innerHTML/outerHTML',
        !RegExp(r'\.(inner|outer)HTML\s*=(?!=)').hasMatch(f.readAsStringSync()));
  }
  final settings = File('templates/settings.html').readAsStringSync();
  check('FIX-40: klucz usuwanych poświadczeń przy przycisku, bez wspólnego ukrytego pola „pole”',
      settings.contains('value="file_delete" formaction="?field={{ p.key }}"') && !settings.contains('name="field"'));
  check('marka przez data-brand, nie w kodzie JS',
      File('templates/_layout.html').readAsStringSync().contains('data-brand="{{ brand }}"') &&
          File('web/ignis/panel.js').readAsStringSync().contains('dataset.brand'));
}
