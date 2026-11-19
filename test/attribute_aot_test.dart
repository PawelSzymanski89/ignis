// `x.y` in a template without dart:mirrors (what an AOT binary uses): collection getters, `operator []`
// (jinja's loop), and a NoSuchMethodError for a plain object field — jinja turns that into an empty value. Bez bazy.
import 'package:ignis/engine/attribute_stub.dart';
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
      readAttribute('length', [1, 2]) == 2 &&
          readAttribute('length', {'a': 1}) == 1 &&
          readAttribute('length', 'abc') == 3);
  check(
      'first / last / isEmpty / isNotEmpty',
      readAttribute('first', [7, 8]) == 7 &&
          readAttribute('last', [7, 8]) == 8 &&
          readAttribute('isEmpty', const []) == true &&
          readAttribute('isNotEmpty', {'a': 1}) == true);
  check(
      'keys / values of a map',
      (readAttribute('keys', {'a': 1}) as Iterable).single == 'a' &&
          (readAttribute('values', {'a': 1}) as Iterable).single == 1);
  Object? error;
  try {
    readAttribute('name', Plain());
  } catch (e) {
    error = e;
  }
  check('an object field is not readable without mirrors (NoSuchMethodError)', error is NoSuchMethodError);

  // jinja's loop variable answers through its own operator [] — the same path as in AOT
  final out = Environment(getAttribute: readAttribute)
      .fromString('{% for x in xs %}{{ loop.index }}{{ x }}{% if loop.last %}.{% endif %}{{ xs.length }}{% endfor %}')
      .render({
    'xs': ['a', 'b']
  });
  check('loop.index / loop.last / xs.length in a for', out == '1a22b.2');
}
