// ============================================================================
//  config.dart — description of the panel configuration fields
// ----------------------------------------------------------------------------
//  Configuration lives in the `settings` table (key→value), but the UI needs
//  to know MORE than the key and value: which section it belongs to, what
//  type it is and — most importantly — whether it is a SECRET.
//
//  🔒 SECRETS NEVER GO BACK TO THE BROWSER. The page only gets the information
//  "set / not set", and an empty field on save means "do not change".
//  Otherwise the secret key would travel in the HTML source on every opening of the tab,
//  and one screenshot or the browser cache would be enough to take it away.
// ============================================================================

import 'ignis.dart';
import 'timezones.dart';

/// `multiline` = a multi-line field (textarea): "one per line" lists, like opening
/// hours or links to review pages.
enum FieldType { text, multiline, password, toggle, choice, number, file }

class Field {
  const Field(this.key, this.label,
      {this.type = FieldType.text,
      this.hint = '',
      this.options = const [],
      this.defaultValue = '',
      this.isRequired = false,
      this.header = '',
      this.check,
      this.max = 10000});

  final String key;
  final String label;
  final FieldType type;
  final String hint;
  final List<String> options; // for FieldType.choice
  final String defaultValue;
  final bool isRequired;

  /// Group heading shown BEFORE this field (empty = no separator).
  final String header;

  /// Validator of a non-empty text value: an error message or null. For fields read by
  /// engine code — a bad value must not break it (e.g. an unknown zone in a schedule).
  final String? Function(String)? check;

  /// Maximum length of a text value — the field may end up on any page.
  final int max;

  /// The value must not go back to the browser (passwords and uploaded credentials).
  bool get secret => type == FieldType.password || type == FieldType.file;
}

class Section {
  const Section(this.id, this.name, this.icon, this.description, this.fields,
      {this.platformOnly = false});
  final String id;
  final String name;
  final String icon;
  final String description;
  final List<Field> fields;

  /// Section visible only in the platform panel (service 0).
  final bool platformOnly;
}

/// All configuration sections. Adding a field here = a field in the panel and in the database,
/// with no template change or migration.
List<Section> get configSections =>
    [..._core, ...Ignis.settingsSections];

const _core = <Section>[
  Section('general', 'General', 'fe fe-sliders', 'Basic site details.', [
    Field('site_name', 'Site name', isRequired: true,
        hint: 'Shown in the browser tab title.'),
    Field('base_url', 'Base URL', hint: 'Used for links in e-mails.', check: httpsUrl),
    Field('contact_email', 'Contact e-mail', max: 254),
    Field('timezone', 'Time zone', defaultValue: 'Europe/Warsaw', check: ianaZone),
    Field('footer', 'Footer'),
  ]),
];

/// Error for the text value [v] of [field] — an i18n key or plain text — or null (empty passes; [Field.isRequired]
/// decides about that). `{max}` in the text is filled with [Field.max].
String? valueError(Field field, String v) =>
    v.length > field.max ? 'ignis.msg.settings.too_long' : v.isEmpty ? null : field.check?.call(v);

/// A full `https://host[/path]` address without credentials.
String? httpsUrl(String v) {
  final u = Uri.tryParse(v);
  return u != null && u.scheme == 'https' && u.host.isNotEmpty && u.userInfo.isEmpty
      ? null
      : 'ignis.msg.settings.https_url';
}

String? ianaZone(String v) => knownZone(v) ? null : 'ignis.msg.settings.unknown_zone';

/// Settings field with key [key], as long as its section is available in this panel
/// (`platformOnly` sections only with [platform]). Null = the key must not be touched.
Field? settingField(String key, {required bool platform}) => [
      for (final s in configSections)
        if (platform || !s.platformOnly) ...s.fields
    ].where((p) => p.key == key).firstOrNull;

/// Keys whose values must not be sent to the browser. Computed once per list of app
/// sections — the audit log filter asks for it for every request parameter.
Set<String> get secretKeys {
  final k = _secretKeys;
  if (k != null && identical(k.$1, Ignis.settingsSections)) return k.$2;
  final fresh = {
    for (final s in configSections)
      for (final p in s.fields)
        if (p.secret) p.key
  };
  _secretKeys = (Ignis.settingsSections, fresh);
  return fresh;
}

(List<Section>, Set<String>)? _secretKeys;

/// Default values of all fields — for seeding the database.
Map<String, String> get defaultSettings => {
      for (final s in configSections)
        for (final p in s.fields)
          if (p.defaultValue.isNotEmpty) p.key: p.defaultValue
    };
