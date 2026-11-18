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
//    • object fields read through mirrors (`p.name`) — in `_attribute()`.
//  Trusted HTML is inserted deliberately, wrapped in `Html('<b>…</b>')` — only
//  this type passes unchanged. Macros and {{ super() }} generate HTML in the template,
//  so we do not touch them.
//
//  ⚠️ JINJA TRAP: in a template with {% extends %} the {% import %}/{% from %} statements
//  must stand INSIDE a block — nothing outside blocks runs and the macro is null.
// ============================================================================

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:jinja/jinja.dart';
import 'package:jinja/loaders.dart';
import 'package:jinja/reflection.dart' show getAttribute;

import 'engine.dart';
import 'ignis.dart';

/// Grosze → „123.45”.
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
  /// Templates of the ignis package: `templates/` next to `lib/` (works with a path dependency too).
  static final String packageTemplates = Isolate.resolvePackageUriSync(
          Uri.parse('package:ignis/ignis.dart'))!
      .resolve('../templates')
      .toFilePath();

  /// Static files of the ignis package (`web/` next to `lib/`) — the last `/assets/` directory, e.g. `/assets/ignis/picker.js`.
  static final String packageAssets = Isolate.resolvePackageUriSync(
          Uri.parse('package:ignis/ignis.dart'))!
      .resolve('../web')
      .toFilePath();

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
      );

  /// `x.y` in a template. Maps are read directly (no mirrors and no
  /// NoSuchMethodError exception on every dot), object fields through reflection — and those
  /// we escape here, because `sanitize()` does not go inside objects.
  static Object? _attribute(String name, Object? object) {
    if (object is Map && object.containsKey(name)) return object[name];
    // `{% for e in map %}` gives a MapEntry from the model map — key and value already escaped
    if (object is MapEntry && (name == 'key' || name == 'value')) return name == 'key' ? object.key : object.value;
    // an object's collection field (List<String>, Map) must go through escaping too —
    // a Map from the model is already clean, but a Map taken out of an object through mirrors is not.
    return sanitize(getAttribute(name, object));
  }

  /// Escapes every String in the model; Html passes untouched.
  static Object? sanitize(Object? v) => switch (v) {
        String s => _esc.convert(s),
        Html h => h,
        // keys too: `{% for k, v in map.items() %}{{ k }}` prints them directly
        Map m => {for (final e in m.entries) sanitize(e.key): sanitize(e.value)},
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
