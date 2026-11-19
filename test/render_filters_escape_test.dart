// HARD-L.13.3: no jinja filter applied to model data may print raw markup. `striptags` of jinja 0.6.7 unescaped
// its result, turning an escaped `<script>` back into markup. `~` and `replace` stay documented exceptions
// (SECURITY.md) — the guards below pin their current behaviour. No database.
// Run: dart run test/render_filters_escape_test.dart
import 'package:ignis/engine/render.dart';
import 'package:jinja/jinja.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

class Shout {
  @override
  String toString() => '<img src=x onerror=1>';
}

void main() {
  String r(String tpl, Map<String, Object?> model) =>
      Environment(getAttribute: Renderer.env.getAttribute, finalize: Renderer.env.finalize, filters: Renderer.env.filters)
          .fromString(tpl)
          .render(Map<String, Object?>.from(Renderer.sanitize(model) as Map));

  const payloads = ['<script>alert(1)</script>', '&lt;b&gt;<img src=x onerror=1>', '<!-- x --><svg onload=1>'];
  const filters = [
    'striptags', 'e', 'escape', 'string', 'upper', 'lower', 'title', 'capitalize', 'trim', 'truncate(200)',
    'wordwrap(5)', 'center(80)', 'default("")', 'list|join', 'reverse|join', 'first', 'last', 'tojson',
  ];
  for (final p in payloads) {
    for (final f in filters) {
      final out = r('{{ x|$f }}', {'x': p});
      check('{{ x|$f }} on ${p.substring(0, 10)}… prints no raw markup', !out.contains('<'));
    }
  }
  check('striptags still strips tags of trusted Html', r('{{ h|striptags }}', {'h': const Html('<b>a</b>  b')}) == 'a b');
  check('striptags keeps entities of trusted Html escaped',
      r('{{ h|striptags }}', {'h': const Html('<i>&lt;x&gt;</i>')}) == '&lt;x&gt;');
  check('striptags removes a multi-line HTML comment of trusted Html',
      r('{{ h|striptags }}', {'h': const Html('a<!-- x > y\nhidden\n-->b')}) == 'ab');
  final attr = r('<a title="{{ h|striptags }}">', {'h': const Html('<a title=">">x</a>" onmouseover=\'1\'')});
  check('striptags escapes " and \' left in trusted Html — the result is safe in an attribute ($attr)',
      !RegExp('["\']').hasMatch(attr.substring(10, attr.length - 2)));

  // documented exceptions (SECURITY.md, "Notes for app authors") — the template author writes them deliberately
  check('`~` with an object whose toString() holds markup prints it raw (documented)',
      r("{{ o ~ '!' }}", {'o': Shout()}).contains('<img'));
  check('`replace` can rebuild markup from entities (documented)',
      r("{{ x|replace('&lt;', '<') }}", {'x': '<script>'}).contains('<script'));
  print('\nALL PASSED');
}
