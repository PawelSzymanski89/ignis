// IGNIS-054.11: an object from the model whose toString() holds markup, passed through a jinja filter that returns a
// String, never prints raw. In jinja 0.7.2 the String filters (upper, lower, trim, title, capitalize, center,
// truncate, wordwrap) take a `String` parameter, so an object is refused at render (TypeError) instead of being
// printed; `|string` / `|join` / `|striptags` are wrapped in Renderer; `format` does not exist. The meta-test makes
// every filter of jinja's default map either wrapped or deliberately allowed — a jinja upgrade that adds a filter
// fails here until somebody reviews it. Functions / tear-offs in the model are out of scope. No database.
// Run: dart run test/render_filters_object_test.dart
import 'package:ignis/engine/render.dart';
import 'package:jinja/jinja.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

class Shout {
  @override
  String toString() => '<script>x</script>';
}

/// Overridden in [Renderer.env] — escape what they print.
const wrapped = {'string', 'join', 'striptags'};

/// Left as jinja has them, with the reason.
const allowed = {
  // escape themselves
  'e', 'escape', 'tojson',
  // String parameter: an object is refused (TypeError); a model string is already escaped
  'upper', 'lower', 'capitalize', 'title', 'center', 'truncate', 'wordwrap', 'trim',
  // documented exception (SECURITY.md): the template author can rebuild markup from entities
  'replace',
  // return the value / elements — printed through Renderer's finalize, which escapes objects
  'd', 'default', 'first', 'last', 'random', 'list', 'reverse', 'slice', 'batch', 'map', 'attr', 'item', 'items',
  'dictsort',
  // numbers / type name
  'filesizeformat', 'wordcount', 'int', 'float', 'abs', 'sum', 'count', 'length', 'runtimetype',
};

void main() {
  String r(String tpl, Map<String, Object?> model) =>
      Environment(getAttribute: Renderer.env.getAttribute, finalize: Renderer.env.finalize, filters: Renderer.env.filters)
          .fromString(tpl)
          .render(Map<String, Object?>.from(Renderer.sanitize(model) as Map));

  const escaped = '&lt;script&gt;x&lt;/script&gt;';
  for (final f in ['upper', 'lower', 'trim', 'title', 'capitalize', 'center(40)', 'truncate(200)', 'wordwrap(80)']) {
    String? out;
    Object? refused;
    try {
      out = r('{{ o|$f }}', {'o': Shout()});
    } catch (e) {
      refused = e;
    }
    check('{{ o|$f }} with markup in toString(): no raw markup (${out ?? 'refused: ${refused.runtimeType}'})',
        out == null ? refused is TypeError : !out.contains('<'));
    final chained = r('{{ o|string|$f }}', {'o': Shout()});
    check('{{ o|string|$f }}: escaped ($chained)', !chained.contains('<') && chained.toLowerCase().contains('&lt;'));
  }
  for (final f in ['string', 'join', 'striptags', 'default', 'first', 'last']) {
    final model = f == 'join' || f == 'first' || f == 'last' ? [Shout()] : Shout();
    final out = r('{{ o|$f }}', {'o': model});
    check('{{ o|$f }}: escaped ($out)', out == escaped);
  }
  check("|format: not in jinja's default filters (nothing to wrap)", !Environment().filters.containsKey('format'));

  final names = Environment().filters.keys.toSet();
  final unreviewed = names.difference({...wrapped, ...allowed});
  check("every default jinja filter is wrapped or deliberately allowed (unreviewed: $unreviewed)", unreviewed.isEmpty);
  check('the wrapped ones are really overridden in Renderer.env',
      wrapped.every((n) => !identical(Renderer.env.filters[n], Environment().filters[n])));
  final stale = {...wrapped, ...allowed}.difference(names);
  check('no listed name that jinja no longer has (stale: $stale)', stale.isEmpty);
  print('\nALL PASSED');
}
