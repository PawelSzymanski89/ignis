// ============================================================================
//  render.dart — template (Jinja) rendering with data from the page model
// ----------------------------------------------------------------------------
//  Templates live in templates/. Jinja gives what Mustache lacked, and without
//  which the panel shell is unmaintainable:
//    {% extends %} / {% block %} / {{ super() }}  — layout in ONE file,
//    {% macro %} + {{ caller() }}                  — components (the equivalent of
//                                                    <#macro>/<#nested> in FreeMarker),
//    {% for %} / {% if %} / filters                — without pushing presentation into Dart.
//
//  ESCAPE (anti-XSS): jinja 0.6.7 has NO autoescape — `{{ x }}` prints raw.
//  So we escape ON OUR SIDE, before data reaches the template:
//    • every String in the model (also in nested Map/List) — in `sanitize()`,
//    • object fields read through mirrors (`p.name`; JIT only — in AOT only `[]`) — in `_attribute()`,
//    • anything else that reaches `{{ }}` (own toString(), exceptions, records), also inside collections
//      and in the `string`/`join` filters — in `_finalize()`,
//    • `striptags` is replaced: jinja's own unescapes its result.
//  The `~` operator concatenates through toString() before `_finalize()`: `{{ obj ~ 'x' }}` with an object
//  whose toString() holds markup prints it raw (SECURITY.md).
//  Trusted HTML is inserted deliberately, wrapped in `Html('<b>…</b>')` — only
//  this type passes unchanged. Macros and {{ super() }} generate HTML in the template,
//  so we do not touch them.
//
//  ⚠️ JINJA TRAP: in a template with {% extends %} the {% import %}/{% from %} statements
//  must stand INSIDE a block — nothing outside blocks runs and the macro is null.
// ============================================================================

import 'dart:convert';
import 'dart:io';

import 'package:jinja/jinja.dart';
import 'package:jinja/loaders.dart';

import 'attribute_stub.dart' if (dart.library.mirrors) 'attribute_mirrors.dart';
import 'engine.dart';
import 'ignis.dart';
import 'package_root.dart';

/// Cents → "123.45".
String money(int cents) => (cents / 100).toStringAsFixed(2);

/// Trusted HTML — the only way for markup from Dart to enter the page without escaping.
///
/// An exception to remember: escaping covers data, not code. The result of a function/tear-off
/// put into the model (`put('f', (x) => '<b>$x</b>')`) and called in the template comes out raw —
/// a function in the model escapes what it returns itself.
class Html {
  const Html(this.text);
  final String text;
  @override
  String toString() => text;
}

class Renderer {
  /// Templates of the ignis package: `templates/` next to `lib/` (works with a path dependency too;
  /// AOT: under IGNIS_PACKAGE_ROOT).
  static final String packageTemplates = '${ignisPackageRoot()}/templates';

  /// Static files of the ignis package (`web/` next to `lib/`) — the last `/assets/` directory, e.g. `/assets/ignis/picker.js`.
  static final String packageAssets = '${ignisPackageRoot()}/web';

  /// Template directories — the first one containing the file wins (app before package).
  static List<String> paths = [packageTemplates];

  static bool exists(String name) => paths.any((s) => File('$s/$name').existsSync());


  static Environment? _env;
  // We escape < > & " ' (safe in content and in attributes), but NOT the slash —
  // the `unknown` mode would turn every '/' in URLs into &#47;.
  static const _esc = HtmlEscape(HtmlEscapeMode(
      name: 'ignis', escapeLtGt: true, escapeQuot: true, escapeApos: true, escapeSlash: false));

  /// Jinja environment — created once. autoReload=false: a template compiles
  /// once, not on every request (by default Jinja read the file from disk and
  /// compiled it again on every render). In dev after a file change: reset().
  static Environment get env => _env ??= Environment(
        loader: FileSystemLoader(paths: paths),
        autoReload: false,
        getAttribute: _attribute,
        finalize: _finalize,
        filters: {'string': _string, 'join': _join, 'striptags': _stripTags},
      );

  /// Last line of defence at every `{{ }}`: values `sanitize()` did not reach print through
  /// `toString()`, so they are escaped here. null prints as ''.
  static Object _finalize(Object? v) => _safe(v) ?? '';

  /// Strings are already clean (model, macro or filter output), Html is trusted; collections are rebuilt with every
  /// other element (object, exception, record) escaped, because they print through the elements' `toString()`.
  static Object? _safe(Object? v) => switch (v) {
        null || String() || num() || bool() || Html() => v,
        Map m => {for (final e in m.entries) _safe(e.key): _safe(e.value)},
        MapEntry e => MapEntry(_safe(e.key), _safe(e.value)),
        Iterable l => [for (final x in l) _safe(x)],
        _ => _esc.convert(v.toString()),
      };

  /// `|string` and `|join` of jinja call `toString()` on objects and return a String, which [_finalize] trusts.
  static String _string(Object? v) => '${_safe(v)}';
  static String _join(Iterable<Object?> values, [String delimiter = '']) => values.map(_safe).join(delimiter);

  /// jinja's `striptags` unescapes its result, turning an escaped `<script>` from the model back into markup.
  /// Here entities stay as they are, and a `<` `>` `"` `'` left over from a broken tag is escaped (safe in an attribute).
  static String _stripTags(Object? v) => '${_safe(v)}'
      .replaceAll(_tags, '')
      .split(_spaces)
      .where((w) => w.isNotEmpty)
      .join(' ')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
  static final _tags = RegExp(r'(<!--[\s\S]*?-->|<[^>]*>)'), _spaces = RegExp(r'\s+');

  /// `x.y` in a template. Maps are read directly (no mirrors and no
  /// NoSuchMethodError exception on every dot), object fields through reflection — and those
  /// we escape here, because `sanitize()` does not go inside objects.
  static Object? _attribute(String name, Object? object) {
    if (object is Map && object.containsKey(name)) return object[name];
    // a MapEntry from the model (or from iterating a model map) — key and value already escaped by sanitize()
    if (object is MapEntry && (name == 'key' || name == 'value')) return name == 'key' ? object.key : object.value;
    // an object's collection field (List<String>, Map) must go through escaping too —
    // a Map from the model is already clean, but a Map taken out of an object through mirrors is not.
    return sanitize(readAttribute(name, object));
  }

  /// Escapes every String in the model; Html passes untouched.
  static Object? sanitize(Object? v) => switch (v) {
        String s => _esc.convert(s),
        Html h => h,
        // keys too: `{% for k, v in map.items() %}{{ k }}` prints them directly
        Map m => {for (final e in m.entries) sanitize(e.key): sanitize(e.value)},
        MapEntry e => MapEntry(sanitize(e.key), sanitize(e.value)),
        Iterable l => [for (final x in l) sanitize(x)],
        _ => v,
      };

  /// Renders template [name] (e.g. "dashboard.html") with [model] → ready HTML.
  static String render(String name, Map<String, Object?> model) =>
      versionAssets(
          env.getTemplate(name).render({...(sanitize(model) as Map).cast<String, Object?>(), 'product': Ignis.brand, 'csp': Engine.cspMeta}),
          Ignis.assetDirs);

  /// Drops the environment — after a template changes on disk (dev).
  static void reset() => _env = null;
}
