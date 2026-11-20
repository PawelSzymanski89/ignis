// `x.y` on a value in a template. The collection getters jinja's loop / namespace and the
// panel templates use, then the value's own `operator []`. Object fields (`{{ page.title }}`) are read through the
// generated attribute getters in render.dart (from the registry); anything with no getter and no `[]` throws
// NoSuchMethodError, which jinja turns into an item lookup and then into an empty value.
Object? collectionAttribute(String name, Object? object) => switch ((name, object)) {
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
