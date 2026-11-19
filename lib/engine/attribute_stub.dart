// `x.y` on an object in a template, AOT (no dart:mirrors): the collection getters templates use, then the
// object's own `operator []` (jinja's loop / namespace). Anything else throws NoSuchMethodError, which jinja
// turns into an item lookup and then into an empty value — put Maps in the model, not objects.
Object? readAttribute(String name, Object? object) => switch ((name, object)) {
      ('length', Iterable o) => o.length,
      ('length', Map o) => o.length,
      ('length', String o) => o.length,
      ('isEmpty', Iterable o) => o.isEmpty,
      ('isEmpty', Map o) => o.isEmpty,
      ('isNotEmpty', Iterable o) => o.isNotEmpty,
      ('isNotEmpty', Map o) => o.isNotEmpty,
      ('first', Iterable o) => o.first,
      ('last', Iterable o) => o.last,
      ('keys', Map o) => o.keys,
      ('values', Map o) => o.values,
      _ => (object as dynamic)[name],
    };
