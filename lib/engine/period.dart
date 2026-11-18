// ============================================================================
//  period.dart — report period from the URL: a preset (`range=24h|7d|30d|90d`) or a custom range of days
//  (`range=custom&from=YYYY-MM-DD&to=YYYY-MM-DD`, both days inclusive, UTC) + comparison with the previous
//  period of the same length (`compare=1`). Template: the `period` macro from `_period.html`.
//
//    final o = Period.fromParams(get, now: DateTime.now());
//    ... WHERE ts >= @from AND ts < @to ...   {'from': o.from, 'to': o.to}
//    if (o.compare) ... {'from': o.previousFrom, 'to': o.from}
// ============================================================================

class Period {
  /// Presets: key → hours. "24h" = the current hour and 23 full ones, "N days" = today and N−1 full days (UTC).
  static const presets = {'24h': 24, '7d': 24 * 7, '30d': 24 * 30, '90d': 24 * 90};
  static const custom = 'custom';
  /// Longest custom range (days).
  static const maxDays = 366;

  /// `24h`, `7d`, `30d`, `90d` or [custom].
  final String range;
  /// Start (ms, inclusive) and end (ms, exclusive; for a range up to today — now).
  final int from, to;
  final bool compare;
  /// Days of the custom range (YYYY-MM-DD) — for the form fields; empty for a preset.
  final String dateFrom, dateTo;
  /// The custom range was invalid (bad date, end before start, > [maxDays]) — [defaultOne] was used.
  final bool error;

  Period._(this.range, this.from, this.to, this.compare, this.dateFrom, this.dateTo, this.error);

  /// Length of the period (ms) and the previous period of the same length right before [from].
  int get length => to - from;
  int get previousFrom => from - length;
  /// Number of days (at least 1) — for reports counted in days.
  int get days => ((length + 86399999) ~/ 86400000).clamp(1, maxDays);
  /// Chart buckets: hourly up to 2 days, daily beyond.
  String get seedValue => length <= 2 * 86400000 ? 'hour' : 'day';

  static DateTime? _day(String? s) {
    if (s == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)) return null;
    final d = DateTime.tryParse('${s}T00:00:00Z');
    return d != null && d.toIso8601String().startsWith(s) ? d : null;
  }

  static String _txt(DateTime d) => d.toIso8601String().substring(0, 10);

  /// Period from the request parameters [get]; [defaultOne] — the preset when missing or invalid.
  factory Period.fromParams(String? Function(String) get, {DateTime? now, String defaultOne = '7d'}) {
    final t = (now ?? DateTime.now()).toUtc();
    final compare = get('compare') == '1';
    final z = get('range');
    if (z == custom) {
      final a = _day(get('from')), b = _day(get('to'));
      final today = DateTime.utc(t.year, t.month, t.day);
      if (a != null && b != null && !b.isBefore(a) && !a.isAfter(today) && b.difference(a).inDays < maxDays) {
        final end = b.isBefore(today) ? b.add(const Duration(days: 1)).millisecondsSinceEpoch : t.millisecondsSinceEpoch;
        return Period._(custom, a.millisecondsSinceEpoch, end, compare, _txt(a), _txt(b.isAfter(today) ? today : b), false);
      }
      return Period._preset(defaultOne, t, compare, error: true);
    }
    return Period._preset(presets.containsKey(z) ? z! : defaultOne, t, compare);
  }

  factory Period._preset(String z, DateTime t, bool compare, {bool error = false}) {
    final h = presets[z]!;
    final from = h == 24 ? DateTime.utc(t.year, t.month, t.day, t.hour - 23) : DateTime.utc(t.year, t.month, t.day - (h ~/ 24 - 1));
    return Period._(z, from.millisecondsSinceEpoch, t.millisecondsSinceEpoch, compare, '', '', error);
  }

  /// URL parameters of this period (for links that keep it).
  Map<String, String> get params => {
        'range': range,
        if (range == custom) ...{'from': dateFrom, 'to': dateTo},
        if (compare) 'compare': '1',
      };

  /// Names of the period parameters (for [PageEngine.queryWithout]).
  static const names = ['range', 'from', 'to', 'compare'];

  static const _month = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  /// Short label of a custom range: pl "20.10–05.11", others "Oct 20 – Nov 5"; the year only outside the current one.
  String label(String language, {DateTime? now}) {
    final a = DateTime.parse('${dateFrom}T00:00:00Z'), b = DateTime.parse('${dateTo}T00:00:00Z');
    final year = (now ?? DateTime.now()).toUtc().year;
    final withYear = a.year != year || b.year != year;
    String d(DateTime x) => language == 'pl'
        ? '${x.day.toString().padLeft(2, '0')}.${x.month.toString().padLeft(2, '0')}${withYear ? '.${x.year}' : ''}'
        : '${_month[x.month - 1]} ${x.day}${withYear ? ', ${x.year}' : ''}';
    return language == 'pl' ? '${d(a)}–${d(b)}' : '${d(a)} – ${d(b)}';
  }

  /// Model for the `period` macro: [db] — the page URL with the other parameters (without period parameters), ends with `?` or `&`.
  Map<String, Object?> model(String db, {String language = 'en'}) {
    String address(Map<String, String> p) => db + p.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');
    final today = DateTime.fromMillisecondsSinceEpoch(to, isUtc: true);
    return {
      'range': range,
      'custom': range == custom,
      'label': range == custom ? label(language) : '',
      'date_from': range == custom ? dateFrom : _txt(DateTime.fromMillisecondsSinceEpoch(from, isUtc: true)),
      'date_to': range == custom ? dateTo : _txt(today),
      'compare': compare,
      'error': error,
      'presets': [
        for (final p in presets.keys) {'k': p, 'href': address({'range': p, if (compare) 'compare': '1'}), 'active': p == range},
      ],
      'toggle_compare': address({...params}..remove('compare')..addAll(compare ? {} : {'compare': '1'})),
      'max': _txt(DateTime.now().toUtc()),
      'fields': [
        for (final e in Uri.splitQueryString(db.contains('?') ? db.substring(db.indexOf('?') + 1) : '').entries)
          if (e.key.isNotEmpty) {'k': e.key, 'v': e.value},
      ],
      'action': db.contains('?') ? db.substring(0, db.indexOf('?')) : db,
    };
  }
}
