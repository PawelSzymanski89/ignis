// ============================================================================
//  settings_page.dart — "/admin/settings" (Configuration)
// ----------------------------------------------------------------------------
//  Sections described declaratively: the "General" core (engine/config.dart) plus
//  app sections from `Ignis.start(settingsSections:)`. Adding a field there = a field
//  here, without touching this class or the template.
//
//  Entry requires `settings.view`, SAVING separately `settings.edit` — an account
//  with view only sees the configuration, but with the fields disabled.
//
//  🔒 Secrets (password and file fields) do NOT reach the
//  template — the page gets only "set: yes/no". An empty field on
//  save means "leave as it was", so the form can be saved without
//  retyping the secrets every time.
// ============================================================================

import '../engine/admin_page.dart';
import '../engine/annotations.dart';
import '../engine/config.dart';
import '../engine/upload.dart';

import '../engine/permissions.dart';
import '../engine/crypto.dart';
import '../engine/i18n.dart';

@Page('/admin/settings',
    template: 'settings.html',
    requires: 'settings.view',
    label: 'Settings',
    icon: 'fe fe-settings',
    order: 60,
    group: 'System',
    // credentials file ≤ 64 KB + form fields
    maxBody: 256 * 1024)
class SettingsPage extends AdminPage {
  @Action('save')
  Future<bool> save() async {
    if (!can('settings.edit')) return missingPermission('settings.edit');

    final sectionId = get('section') ?? 'general';
    final section = configSections.where((s) => s.id == sectionId).firstOrNull;
    if (section == null) return back('/admin/settings', message: t('ignis.msg.settings.unknown_section'), type: 'danger');
    // platform sections cannot be saved from a service panel, even knowing their name
    if (section.platformOnly && !context.platform) {
      return back('/admin/settings', message: t('ignis.msg.settings.not_yours'), type: 'danger');
    }

    final current = await Permissions.settings(context.service);
    var changes = 0;

    // Uploaded credentials (`file` fields) — validated by CONTENT, not by extension.
    for (final field in section.fields.where((p) => p.type == FieldType.file)) {
      final f = uploadedFile('p_${field.key}');
      if (f == null) continue;
      final error = await _acceptCredentials(field.key, f);
      if (error != null) {
        return back('/admin/settings?s=$sectionId', message: t(error), type: 'danger');
      }
      changes++;
    }

    for (final field in section.fields) {
      final raw = get('p_${field.key}');
      String fresh;

      switch (field.type) {
        case FieldType.toggle:
          // an unchecked checkbox is NOT sent in a POST — that is exactly "off"
          fresh = raw == 'on' ? '1' : '0';
        case FieldType.file:
          continue; // handled separately by the `upload` action
        case FieldType.password:
          // empty = do not change (the secret is not sent back to the form, so there is nothing to send)
          if (raw == null || raw.isEmpty) continue;
          fresh = raw.trim();
        case FieldType.number:
          if (raw == null) continue;
          final l = num.tryParse(raw.trim().replaceAll(',', '.'));
          if (l == null) {
            return back('/admin/settings?s=$sectionId',
                message: t('ignis.msg.settings.not_number', {'field': _label(field)}), type: 'danger');
          }
          fresh = l.toString();
        case FieldType.choice:
          if (raw == null) continue;
          fresh = raw.trim();
          if (!field.options.contains(fresh)) {
            return back('/admin/settings?s=$sectionId',
                message: t('ignis.msg.settings.pick_option', {'field': _label(field)}), type: 'danger');
          }
        default:
          if (raw == null) continue;
          fresh = raw.trim();
          if (Crypto.looksEncrypted(fresh)) {
            return back('/admin/settings?s=$sectionId',
                message: t('ignis.msg.settings.no_enc', {'field': _label(field)}), type: 'danger');
          }
          if (field.isRequired && fresh.isEmpty) {
            return back('/admin/settings?s=$sectionId',
                message: t('ignis.msg.settings.required', {'field': _label(field)}), type: 'danger');
          }
          final error = valueError(field, fresh);
          if (error != null) {
            return back('/admin/settings?s=$sectionId', message: t('ignis.msg.settings.invalid', {'field': _label(field), 'error': _text(error, {'max': field.max})}), type: 'danger');
          }
      }

      if (fresh != (current[field.key] ?? '')) {
        await Permissions.saveSetting(context.service, field.key, fresh);
        changes++;
      }
    }

    return back('/admin/settings?s=$sectionId',
        message: changes == 0 ? t('ignis.msg.settings.unchanged') : t('ignis.msg.settings.saved', {'n': changes}),
        type: changes == 0 ? 'info' : 'success');
  }

  @Action('file_delete')
  Future<bool> deleteFile() async {
    if (!can('settings.edit')) return missingPermission('settings.edit');
    final key = get('field') ?? '';
    // only uploaded credentials from this panel's sections — not any settings key
    if (settingField(key, platform: context.platform)?.type != FieldType.file) {
      return back('/admin/settings', message: t('ignis.msg.settings.unknown_field'), type: 'danger');
    }
    await Permissions.saveSetting(context.service, key, '');
    return back('/admin/settings?s=${get('section') ?? 'general'}',
        message: t('ignis.msg.settings.creds_deleted'), type: 'warning');
  }

  /// Checks and saves an uploaded credentials file. Returns the i18n key of the error, or null.
  Future<String?> _acceptCredentials(String key, UploadedFile f) async {
    if (f.size > 64 * 1024) {
      return 'ignis.msg.settings.creds_too_big';
    }
    final String text;
    try {
      text = f.text;
    } on FormatException {
      return 'ignis.msg.settings.creds_not_utf8';
    }
    await Permissions.saveSetting(context.service, key, text);
    return null;
  }

  /// Field label in the page language (`ignis.setting.<key>.label`), else the label from its definition.
  String _label(Field f) => I18n.find(language, 'ignis.setting.${f.key}.label') ?? f.label;

  /// [error] as an i18n key when the catalog has it, else the validator's own text.
  String _text(String error, Map<String, Object> params) => I18n.find(language, error) != null ? t(error, params) : error;

  @override
  Future<void> insertData() async {
    await sharedData();
    final u = await Permissions.settings(context.service);

    put('sections', [
      for (final s in configSections)
        if (!s.platformOnly || context.platform)
        {
          'id': s.id,
          'name': I18n.find(language, 'ignis.settings.section.${s.id}.name') ?? s.name,
          'icon': s.icon,
          'description': I18n.find(language, 'ignis.settings.section.${s.id}.description') ?? s.description,
          'active': s.id == (get('s') ?? 'general'),
          'fields': [
            for (final p in s.fields)
              {
                'key': p.key,
                'label': _label(p),
                'hint_text': I18n.find(language, 'ignis.setting.${p.key}.hint') ?? p.hint,
                'type': p.type.name,
                'options': p.options,
                'required': p.isRequired,
                // 🔒 the secret value does NOT go to the template — only whether it is set
                'value': p.secret ? '' : (u[p.key] ?? p.defaultValue),
                'is_set': (u[p.key] ?? '').isNotEmpty,
                'enabled': (u[p.key] ?? p.defaultValue) == '1',
                'secret': p.secret,
                'heading': p.header,
              }
          ],
        }
    ]);
    put('can_edit', can('settings.edit'));
  }
}
