// ============================================================================
//  i18n.dart — template texts in several languages
// ----------------------------------------------------------------------------
//  The app keeps `i18n/<language>.json` (a flat key → text map), the template
//  calls `{{ t('crashes.title') }}`. Language: `?lang=` (stored in a cookie)
//  > cookie > Accept-Language > the first of `Ignis.start(languages:)`.
//  Missing key → the text from the default language, and when missing there too — the key itself;
//  each gap logged once, so a hole in the file is visible while the page keeps working.
//  Texts from the app's files are trusted — the template prints them without escaping.
// ============================================================================

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

class I18n {
  static const cookie = 'lang';

  /// Languages of the built-in panel catalog (`i18n/<lang>.json` of the package); the first is the default.
  static const builtInLanguages = ['en', 'pl'];

  /// Supported languages; the first is the default. Without app catalogs: [builtInLanguages].
  static List<String> languages = builtInLanguages;
  static final Map<String, Map<String, String>> _texts = {};
  static final Set<String> _logged = {};

  static final String packageCatalog = Isolate.resolvePackageUriSync(Uri.parse('package:ignis/ignis.dart'))!
      .resolve('../i18n')
      .toFilePath();
  static final Map<String, Map<String, String>> _builtIn = {
    for (final j in builtInLanguages)
      j: {
        for (final e in (jsonDecode(File('$packageCatalog/$j.json').readAsStringSync()) as Map).entries)
          e.key as String: e.value as String,
      },
  };

  /// Reads `<catalog>/<language>.json` for every language. A missing file = startup error.
  static void load(String catalog, List<String> languages) {
    I18n.languages = languages;
    _texts.clear();
    for (final j in languages) {
      final m = jsonDecode(File('$catalog/$j.json').readAsStringSync()) as Map;
      _texts[j] = {for (final e in m.entries) e.key as String: e.value as String};
    }
  }

  /// Sets the texts directly (tests, apps without files).
  static void set(Map<String, Map<String, String>> texts) {
    languages = texts.keys.toList();
    _texts
      ..clear()
      ..addAll(texts);
  }

  /// Texts of a language (e.g. to check completeness in app tests).
  static Map<String, String> texts(String language) => _texts[language] ?? const {};

  /// Language choice in the order from the file header.
  static String pick({String? param, String? cookieValue, String? acceptLanguage}) {
    for (final j in [param, cookieValue]) {
      if (j != null && languages.contains(j)) return j;
    }
    for (final part in (acceptLanguage ?? '').split(',')) {
      final j = part.split(';').first.trim().toLowerCase().split('-').first;
      if (languages.contains(j)) return j;
    }
    return languages.first;
  }

  /// Text of [key] in [language] (app or built-in catalog), null when neither has it — no fallback, no log.
  static String? find(String language, String key) => _texts[language]?[key] ?? _builtIn[language]?[key];

  /// App text → built-in panel text of [language] → app default language → built-in English → the key.
  static String t(String language, String key) {
    final w = _texts[language]?[key] ?? _builtIn[language]?[key];
    if (w != null) return w;
    if (_logged.add('$language|$key')) {
      stdout.writeln('i18n: missing key "$key" ($language)');
    }
    return _texts[languages.first]?[key] ?? _builtIn['en']![key] ?? key;
  }

  /// CLDR plural category for an integer: one | few | many | other (pl: 1 / 2–4, 22–24… / 5+, 12–14;
  /// languages without inflection as in en: one | other).
  static String pluralCategory(String language, int n) {
    final a = n.abs(), d = a % 10, s = a % 100;
    return switch (language) {
      'pl' => a == 1 ? 'one' : d >= 2 && d <= 4 && (s < 12 || s > 14) ? 'few' : 'many',
      'cs' || 'sk' => a == 1 ? 'one' : a >= 2 && a <= 4 ? 'few' : 'other',
      'uk' || 'ru' => d == 1 && s != 11 ? 'one' : d >= 2 && d <= 4 && (s < 12 || s > 14) ? 'few' : 'many',
      _ => a == 1 ? 'one' : 'other',
    };
  }

  /// Text with a count: `key.one|few|many|other` by [pluralCategory] (missing form → `.other` → `.many`),
  /// `{n}` in the text replaced with the number (or [format] of the number, e.g. with a thousands separator).
  /// In a template: `{{ tn('devices.count', 3) }}` → "3 devices".
  static String tn(String language, String key, int n, {String Function(int)? format}) {
    final k = pluralCategory(language, n);
    String? z(String f) =>
        _texts[language]?['$key.$f'] ?? _builtIn[language]?['$key.$f'] ?? _texts[languages.first]?['$key.$f'] ?? _builtIn['en']![
            '$key.$f'];
    final w = z(k) ?? z('other') ?? z('many') ?? t(language, '$key.$k');
    return w.replaceAll('{n}', format == null ? '$n' : format(n));
  }
}

/// Engine error page texts (`ignis.error.<kind>.title|text`, `ignis.error.home|back`) live in the built-in
/// catalog (`i18n/en.json`, `i18n/pl.json`); the app's key wins (own wording, more languages).
class ErrorTexts {
  /// Error page kind for a status set by the page (notFound(), forbidden()…).
  static String kindForStatus(int code) => switch (code) {
        404 || 410 => 'not_found',
        401 || 403 => 'forbidden',
        400 || 422 => 'bad_data',
        413 => 'too_large',
        405 => 'method',
        >= 500 => 'server',
        _ => 'other',
      };

  /// Translator for [language]; a language outside the app list falls back to built-in English.
  static String Function(String) t(String language) => (String key) => I18n.languages.contains(language) ||
          I18n._builtIn.containsKey(language)
      ? I18n.t(language, key)
      : I18n._texts[language]?[key] ?? I18n._builtIn['en']![key] ?? key;
}
