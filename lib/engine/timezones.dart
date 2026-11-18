// ============================================================================
//  timezones.dart — strefy czasowe IANA i harmonogramy (jednorazowo / codziennie / tygodniowo)
// ----------------------------------------------------------------------------
//  The tzdata database is in the `timezone` package (no system files), so the result does not depend on
//  the server's zone. Wall-clock time in a zone → a UTC instant; around clock changes, a time
//  that does not exist (e.g. 02:30 in March in Europe) moves by the length of the gap (→ 03:30, like
//  java.time), and an ambiguous one (in autumn) takes the first occurrence.
// ============================================================================

import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

part 'timezones_by_country.dart';

bool _loaded = false;
void _loadNow() {
  if (_loaded) return;
  tzdata.initializeTimeZones();
  _loaded = true;
}

/// Whether [name] is a known IANA zone (e.g. `Europe/Warsaw`, `UTC`).
bool knownZone(String name) {
  _loadNow();
  try {
    tz.getLocation(name);
    return true;
  } on tz.LocationNotFoundException {
    return false;
  }
}

/// All IANA zone names, sorted (for choice lists).
List<String> zoneNames() {
  _loadNow();
  return tz.timeZoneDatabase.locations.keys.toList()..sort();
}

/// Offset of zone [zone] from UTC at instant [ms] (epoch ms), in minutes.
int offsetMin(String zone, int ms) {
  _loadNow();
  return tz.getLocation(zone).timeZone(ms).offset ~/ 60000;
}

/// UTC instant (epoch ms) of wall-clock time [year]-[month]-[day] [hour]:[min] in zone [zone].
int instantInZone(String zone, int year, int month, int day, int hour, int min) {
  _loadNow();
  final l = tz.getLocation(zone);
  final naive = DateTime.utc(year, month, day, hour, min).millisecondsSinceEpoch;
  // two approximations of the offset: before and after a possible clock change; the first instant whose
  // wall-clock time matches, and when none does (spring gap) — the later one (= shifted by the gap).
  final candidates = {for (final p in [l.timeZone(naive - 86400000).offset, l.timeZone(naive + 86400000).offset]) naive - p}.toList()..sort();
  for (final c in candidates) {
    if (c + l.timeZone(c).offset == naive) return c;
  }
  return candidates.last;
}

/// Wall-clock date (year, month, day, weekday 1=Mon…7=Sun) of instant [ms] in zone [zone].
({int year, int month, int day, int weekday, int hour, int min}) wallInZone(String zone, int ms) {
  _loadNow();
  final d = DateTime.fromMillisecondsSinceEpoch(ms + tz.getLocation(zone).timeZone(ms).offset, isUtc: true);
  return (year: d.year, month: d.month, day: d.day, weekday: d.weekday, hour: d.hour, min: d.minute);
}

/// IANA zone of country [country] (ISO alpha-2, any case); null when the country has zones with different times
/// (US, BR, RU, AU, ES, PT…) or is unknown.
String? countryZone(String country) => _countryZone[country.toUpperCase()];

/// Country → its only zone map (for SQL queries that resolve the zone on the database side).
Map<String, String> get countryZones => _countryZone;

/// Recipient zone: [tz] (IANA, when known) → the zone of country [country] (when it is the only one) → [defaultValue].
String recipientZone({String tz = '', String country = '', required String defaultValue}) {
  if (tz.isNotEmpty && knownZone(tz)) return tz;
  return countryZone(country) ?? defaultValue;
}

/// Sending schedule: [hour]:[min] in a zone; [weekdays] empty = every day, otherwise only those days (1=Mon…7=Sun).
class Recurring {
  const Recurring(this.hour, this.min, {this.weekdays = const {}});
  final int hour, min;
  final Set<int> weekdays;

  /// The nearest instant (epoch ms) STRICTLY after [after] in zone [zone].
  int next(String zone, int after) {
    final s = wallInZone(zone, after);
    for (var i = 0; i <= 8; i++) {
      final d = DateTime.utc(s.year, s.month, s.day + i);
      if (weekdays.isNotEmpty && !weekdays.contains(d.weekday)) continue;
      final c = instantInZone(zone, d.year, d.month, d.day, hour, min);
      if (c > after) return c;
    }
    throw StateError('Recurring: no occurrence within 8 days (weekdays=$weekdays)');
  }
}
