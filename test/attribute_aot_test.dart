// `x.y` in a template without reflection — the same path in JIT and AOT: collection getters, `operator []`
// (jinja's loop), generated getters for registry classes, and an empty value for any other object. Bez bazy.
import 'package:ignis/engine/attribute.dart';
import 'package:ignis/ignis.dart';
import 'package:ignis/ignis_registry.g.dart';
import 'package:jinja/jinja.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

class Plain {
  final String name = 'x';
}

void main() {
  check(
      'length of a list, map and string',
      collectionAttribute('length', [1, 2]) == 2 &&
          collectionAttribute('length', {'a': 1}) == 1 &&
          collectionAttribute('length', 'abc') == 3);
  check(
      'first / last / isEmpty / isNotEmpty',
      collectionAttribute('first', [7, 8]) == 7 &&
          collectionAttribute('last', [7, 8]) == 8 &&
          collectionAttribute('isEmpty', const []) == true &&
          collectionAttribute('isNotEmpty', {'a': 1}) == true);
  check(
      'keys / values of a map',
      (collectionAttribute('keys', {'a': 1}) as Iterable).single == 'a' &&
          (collectionAttribute('values', {'a': 1}) as Iterable).single == 1);
  Object? error;
  try {
    collectionAttribute('name', Plain());
  } catch (e) {
    error = e;
  }
  check('a plain object field has no getter (NoSuchMethodError)', error is NoSuchMethodError);

  final out = Environment(getAttribute: collectionAttribute)
      .fromString('{% for x in xs %}{{ loop.index }}{{ x }}{% if loop.last %}.{% endif %}{{ xs.length }}{% endfor %}')
      .render({
    'xs': ['a', 'b']
  });
  check('loop.index / loop.last / xs.length in a for', out == '1a22b.2');

  print('Renderer with the generated getters:');
  Renderer.attributeGetters = ignisRegistry.attributes;
  String r(String tpl, Map<String, Object?> model) =>
      Environment(getAttribute: Renderer.env.getAttribute, finalize: Renderer.env.finalize)
          .fromString(tpl)
          .render(Map<String, Object?>.from(Renderer.sanitize(model) as Map));
  final user = User()
    ..username = '<b>ala</b>'
    ..realm = 'staff';
  check('entity field through the generated getter, escaped',
      r('{{ u.username }}|{{ u.realm }}', {'u': user}) == '&lt;b&gt;ala&lt;/b&gt;|staff');
  check('unknown field of a registry class → empty', r('[{{ u.nope }}]', {'u': user}) == '[]');
  check('object outside the registry → empty (as in AOT before)', r('[{{ o.name }}]', {'o': Plain()}) == '[]');
  check('maps work as before', r('{{ m.name }}', {'m': {'name': '<i>'}}) == '&lt;i&gt;');
}
