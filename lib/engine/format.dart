// ============================================================================
//  format.dart — shared value formats in panels: duration, country name
// ----------------------------------------------------------------------------
//  A duration has one shape across the whole scale, always with two units
//  when longer than seconds: `0:46` / `1:53` / `1:02:05` (clock-like) —
//  a column of numbers lines up and does not mix "46s" with "1m 53s".
//  Country: `Poland (PL)` — the name in the interface language and the ISO code the user
//  types in filters; an unknown code stays as is.
// ============================================================================

import 'i18n.dart';

part 'country_formats.dart';

/// Duration from milliseconds as a clock: `m:ss` below an hour, `h:mm:ss` from an hour
/// (rounded to a full second). Negative → `0:00`.
String duration(num ms) {
  final s = ms <= 0 ? 0 : (ms / 1000).round();
  String d2(int v) => v.toString().padLeft(2, '0');
  final h = s ~/ 3600, m = s % 3600 ~/ 60, sec = s % 60;
  return h > 0 ? '$h:${d2(m)}:${d2(sec)}' : '$m:${d2(sec)}';
}

/// Country name for an ISO 3166-1 alpha-2 code in [language] (`ignis.country.<CODE>` from the i18n catalogs,
/// else English); null for an unknown code.
String? countryName(String code, String language) {
  final c = code.toUpperCase(), n = _countryNames[c];
  return n == null ? null : I18n.find(language, 'ignis.country.$c') ?? n;
}

/// `Poland (PL)`; an unknown code → the code itself, empty → empty.
String countryWithCode(String code, String language) {
  final n = countryName(code, language);
  return n == null ? code : '$n (${code.toUpperCase()})';
}

/// Change against the previous period: `{'text': '+12.5%', 'direction': 'up'|'down'|'flat'}`;
/// null when the previous value was 0 (a percentage makes no sense). [language] `pl` → decimal comma.
Map<String, String>? periodChange(num now, num before, String language) {
  if (before == 0) return null;
  final z = 100 * (now - before) / before;
  final s = z.abs().toStringAsFixed(1);
  return {
    'text': '${z > 0 ? '+' : z < 0 ? '−' : '±'}${language == 'pl' ? s.replaceAll('.', ',') : s}\u00a0%',
    'direction': z > 0 ? 'up' : z < 0 ? 'down' : 'flat',
  };
}
