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

class Shout {
  @override
  String toString() => '<img src=x onerror=1>';
}

void main() {
  // what the registry builder generates for a registry class (here by hand: Obj is a test class)
  Renderer.attributeGetters = {
    Obj: {'name': (o) => (o as Obj).name, 'list': (o) => (o as Obj).list, 'map': (o) => (o as Obj).map},
  };
  String r(String tpl, Map<String, Object?> model) =>
      Environment(getAttribute: Renderer.env.getAttribute, finalize: Renderer.env.finalize, filters: Renderer.env.filters)
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
  check('pole obiektu przez wygenerowany getter',
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
  check('obiekt spoza rejestru → pusto', r('[{{ s.name }}]', {'s': Shout()}) == '[]');

  print('HARD-L.6 — values that used to print raw:');
  const x = '<img src=x onerror=1>';
  const xe = '&lt;img src=x onerror=1&gt;';
  check('list of MapEntry (map.entries.toList())',
      r('{% for e in l %}{{ e.key }}={{ e.value }}{% endfor %}', {'l': {x: x}.entries.toList()}) == '$xe=$xe');
  check('single MapEntry', r('{{ e.key }}|{{ e.value }}', {'e': const MapEntry(x, x)}) == '$xe|$xe');
  check('object with its own toString()', r('{{ o }}', {'o': Shout()}) == xe);
  check('exception (FormatException)', r('{{ e }}', {'e': const FormatException(x)}) == 'FormatException: $xe');
  check('record (String, int)', r('{{ t }}', {'t': (x, 1)}) == '($xe, 1)');
  check('Set<String> still escaped once', r('{% for s in z %}{{ s }}{% endfor %}', {'z': {x}}) == xe);
  check('Html still passes unchanged', r('{{ h }}', {'h': const Html(x)}) == x);
  check('macro output not escaped',
      r('{% macro b(t) %}<b>{{ t }}</b>{% endmacro %}{{ b(x) }}', {'x': x}) == '<b>$xe</b>');
  check('filters work on escaped values', r('{{ x|upper }}|{{ l|join(",") }}', {'x': 'a<', 'l': ['<', 'b']}) == 'A&LT;|&lt;,b');
  check('null prints empty', r('[{{ n }}]', {'n': null}) == '[]');

  print('HARD-L.12.4 — collections and the string/join filters:');
  final mixed = {'l': [Shout(), const FormatException(x), (x, 1)]};
  const shown = '$xe, FormatException: $xe, ($xe, 1)';
  check('{{ l }} with an object, an exception and a record', r('{{ l }}', mixed) == '[$shown]');
  check("{{ l|join(', ') }}", r("{{ l|join(', ') }}", mixed) == shown);
  check('{{ o|string }} for a list', r('{{ o|string }}', {'o': mixed['l']}) == '[$shown]');
  check('{{ o|string }} for an object', r('{{ o|string }}', {'o': Shout()}) == xe);
  check('{{ m }} with an object value', r('{{ m }}', {'m': {'k': Shout()}}) == '{k: $xe}');
  check('strings in a joined list escaped once', r('{{ l|join }}', {'l': [x, 1]}) == '${xe}1');
  check('Html in a list and in join passes unchanged',
      r('{{ l }}|{{ l|join }}|{{ h|string }}', {'l': [const Html('<b>')], 'h': const Html('<i>')}) == '[<b>]|<b>|<i>');
  check('super() and caller() unchanged',
      Environment(loader: MapLoader({'base': '{% block b %}<p>{% endblock %}'}), finalize: Renderer.env.finalize,
                  filters: Renderer.env.filters)
                  .fromString("{% extends 'base' %}{% block b %}{{ super() }}<q>{% endblock %}")
                  .render() ==
              '<p><q>' &&
          r('{% macro w() %}<b>{{ caller() }}</b>{% endmacro %}{% call w() %}<i>{% endcall %}', {}) == '<b><i></b>');

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
