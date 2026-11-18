// Test escape'u w renderze — bez bazy, bez Redisa, tylko szablon ze stringa.
// Uruchomienie: dart test/render_test.dart
import 'dart:io';

import 'package:jinja/jinja.dart';

import '../lib/engine/render.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

class Obj {
  final String name = '<i>obiekt</i>';
  final List<String> list = ['<b>'];
  final Map<String, String> map = {'k': '<u>'};
}

void main() {
  String r(String tpl, Map<String, Object?> model) =>
      Environment(getAttribute: Renderer.env.getAttribute)
          .fromString(tpl)
          .render(Map<String, Object?>.from(Renderer.sanitize(model) as Map));

  print('escape:');
  check('string z modelu jest escapowany',
      r('{{ x }}', {'x': '<script>alert(1)</script>'}) == '&lt;script&gt;alert(1)&lt;/script&gt;');
  check('cudzysłów i apostrof (atrybuty)',
      r('{{ x }}', {'x': '"a\'b'}) == '&quot;a&#39;b');
  check('ukośnik zostaje (adresy)',
      r('{{ x }}', {'x': '/admin/files?f=/a/'}) == '/admin/files?f=/a/');
  check('zagnieżdżona mapa i lista',
      r('{{ m.a }}|{{ l[0] }}', {'m': {'a': '<b>'}, 'l': ['<i>']}) == '&lt;b&gt;|&lt;i&gt;');
  check('pole obiektu przez mirrors',
      r('{{ o.name }}', {'o': Obj()}) == '&lt;i&gt;obiekt&lt;/i&gt;');
  check('pola-kolekcje obiektu też escapowane (nie tylko String)',
      r('{{ o.list[0] }}|{{ o.map.k }}', {'o': Obj()}) == '&lt;b&gt;|&lt;u&gt;');
  check('Html przechodzi bez zmian',
      r('{{ x }}', {'x': const Html('<b>ok</b>')}) == '<b>ok</b>');
  check('liczby i bool bez zmian', r('{{ a }}{{ b }}', {'a': 7, 'b': true}) == '7true');
  check('FIX-50: klucze map escapowane (pętla po mapie)',
      r('{% for k, v in m|items %}{{ k }}={{ v }}{% endfor %}|{{ m|list }}', {'m': {'<i>': '<b>'}}) ==
          '&lt;i&gt;=&lt;b&gt;|[&lt;i&gt;]');
  check('FIX-50: e.key/e.value w pętli po mapie — raz, nie podwójnie',
      r('{% for e in m %}{{ e.key }}={{ e.value }}{% endfor %}', {'m': {'<i>': '<b>'}}) == '&lt;i&gt;=&lt;b&gt;');
  check('FIX-50: lookup po kluczu ze zwykłych znaków dalej działa', r('{{ m.a_b }}', {'m': {'a_b': 'x'}}) == 'x');
  check('length na mapie dalej działa', r('{{ m.length }}', {'m': {'a': 1, 'b': 2}}) == '2');

  print('szablony z kilku katalogów:');
  final app = Directory.systemTemp.createTempSync('ignis_szablony_');
  File('${app.path}/error.html').writeAsStringSync('aplikacja {{ x }}');
  Renderer.paths = [app.path, Renderer.packageTemplates];
  Renderer.reset();
  check('szablon pakietu jest widoczny', Renderer.exists('_layout.html'));
  check('szablon aplikacji nadpisuje pakiet', Renderer.render('error.html', {'x': '<b>'}) == 'aplikacja &lt;b&gt;');
  app.deleteSync(recursive: true);
  print('WSZYSTKO OK');
}
