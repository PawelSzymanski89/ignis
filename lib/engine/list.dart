// ============================================================================
//  list.dart — shared list mechanism: search (q), sorting (sort, dir),
//  pagination (page) from the request URL.
// ----------------------------------------------------------------------------
//  The page gives a whitelist of sorts (key from the URL → SQL expression), so
//  nothing from the URL reaches SQL except the LIMIT/OFFSET numbers. The template gets
//  a model with ready links (they keep other parameters, e.g. tenant, filter)
//  and macros from `_list.html`: sort_th, pager, search. The flash message (back) does not pass into links.
//
//    final l = Listing.fromPage(this, sorting: {'date': 'created_at', 'name': 'lower(name)'}, defaults: 'date');
//    ... WHERE ... ${l.search.isEmpty ? '' : 'AND name ILIKE @q'} ${l.sql}
//    if (l.outOfRange(total)) return;   // page=9 with 3 rows → 302 to the last one
//    put('list', l.model(total));
//
//  CSV export of the same view (`format=csv`, link `list.csv`, macro `export`): [sql] without pagination
//  (up to [limitCsv] rows), after the query the page calls `return l.export(name, header, rows)` before put().
// ============================================================================

import 'csv.dart' as csv_file;
import 'page_engine.dart';

class Listing {
  final String search;
  final String sort;
  final bool descending;
  final int page;
  final int onPage;
  final String _column;
  final String _route;
  final Map<String, String> _rest;
  final List<String> _keys;
  final Set<String> _ascending;
  final Set<String> _filters;
  final PageEngine _p;
  final List<int> _sizes;

  Listing._(this.search, this.sort, this.descending, this.page, this.onPage, this._column, this._route, this._rest,
      this._keys, this._ascending, this._filters, this._p, this._sizes);

  /// Reads `q`, `sort`, `dir` (asc/desc), `page` (from 1). Unknown sort → [defaults].
  /// Without `dir`: ascending for keys in [ascending] (e.g. name), descending for the rest (dates, numbers).
  /// [filters] — page parameters that "Clear filters" removes together with `q` (e.g. status);
  /// the rest (tenant, channel tab, panel date range) stays.
  factory Listing.fromPage(PageEngine p,
      {required Map<String, String> sorting,
      required String defaults,
      Set<String> ascending = const {},
      Set<String> filters = const {},
      int onPage = 50,
      List<int> sizes = const [25, 50, 100, 200]}) {
    final s = sorting.containsKey(p.get('sort')) ? p.get('sort')! : defaults;
    final k = p.get('dir');
    final m = k == 'asc' ? false : k == 'desc' ? true : !ascending.contains(s);
    final n = int.tryParse(p.get('page') ?? '') ?? 1;
    // `per_page` = rows per page, only from [sizes] (another value → default); kept in sort and page links
    final requestedSize = int.tryParse(p.get('per_page') ?? '');
    return Listing._((p.get('q') ?? '').trim(), s, m, n.clamp(1, 1000000), sizes.contains(requestedSize) ? requestedSize! : onPage, sorting[s]!, p.meta.route,
        p.paramsWithout(const ['q', 'sort', 'dir', 'page', 'format', 'flash', 'flash_type', 'flash_sig']), sorting.keys.toList(), ascending, filters, p,
        sizes);
  }

  /// Max rows in one CSV export (the whole filter, no pages).
  static const limitCsv = 10000;

  /// Request for a CSV file instead of a page (`format=csv`).
  bool get csv => _p.get('format') == 'csv';

  /// CSV file with the same filter and sort as the view; name `<name>-YYYY-MM-DD.csv`. Returns false (no render).
  bool export(String name, List<String> header, Iterable<List<Object?>> rows) =>
      _p.attachment('$name-${DateTime.now().toUtc().toIso8601String().substring(0, 10)}.csv', csv_file.csv(header, rows),
          type: 'text/csv; charset=utf-8');

  int _pages(int total) => total == 0 ? 1 : (total + onPage - 1) ~/ onPage;

  String _perPage(int s) => _address({..._current, 'sort': sort, 'dir': descending ? 'desc' : 'asc', if (s > 1) 'page': '$s'});

  /// A page out of range (e.g. `page=2` with 3 rows, after the last ones were deleted) → 302 to
  /// the last existing one; true = response set, the page renders nothing.
  bool outOfRange(int total) {
    if (csv || page <= _pages(total)) return false;
    _p.redirect(_perPage(_pages(total)));
    return true;
  }

  /// Pattern for `ILIKE @q` — the % _ \ characters of the phrase literally.
  String get pattern => '%${search.replaceAllMapped(RegExp(r'[%_\\]'), (m) => '\\${m[0]}')}%';

  int get offset => (page - 1) * onPage;

  /// ` ORDER BY … LIMIT … OFFSET …` — column from the whitelist, a second key [id] stabilizes the order.
  String sqlZ({String id = 'id'}) => ' ORDER BY $_column ${descending ? 'DESC' : 'ASC'}, $id ${descending ? 'DESC' : 'ASC'} '
      '${csv ? 'LIMIT $limitCsv' : 'LIMIT $onPage OFFSET $offset'}';

  String get sql => sqlZ();

  String _address(Map<String, String> p) =>
      '$_route?${[for (final e in p.entries) '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}'].join('&')}';

  Map<String, String> get _current => {..._rest, if (search.isNotEmpty) 'q': search};

  /// Model for the template; [total] = number of all matching rows.
  Map<String, Object?> model(int total) {
    final pages = _pages(total);
    final perPage = _perPage;
    return {
      'q': search, 'sort': sort, 'dir': descending ? 'desc' : 'asc', 'page': page, 'pages': pages, 'total': total,
      'first': total == 0 ? 0 : offset + 1, 'last': (offset + onPage) < total ? offset + onPage : total,
      'prev_url': page > 1 ? perPage(page - 1) : null,
      'next_url': page < pages ? perPage(page + 1) : null,
      'action': _route,
      // The same view (phrase, sort, page) — return after a POST action from a row.
      'current': perPage(page),
      // Export: the whole filter and sort, no page.
      'csv': _address({..._current, 'sort': sort, 'dir': descending ? 'desc' : 'asc', 'format': 'csv'}),
      // Phrase to append to the page's tab/filter links (`…&status=x{{ l.with_q }}`); empty without a search.
      'with_q': search.isEmpty ? '' : '&q=${Uri.encodeQueryComponent(search)}',
      // Empty result: is it because of search/filters (then "No results" + clear), or is the list empty.
      'filtered': search.isNotEmpty || _filters.any((f) => (_rest[f] ?? '').isNotEmpty),
      'clear': _address({for (final e in _rest.entries) if (!_filters.contains(e.key)) e.key: e.value}),
      // Search form fields: everything except q and page (sort stays, a new phrase = page 1).
      'hidden': [
        for (final e in {..._rest, 'sort': sort, 'dir': descending ? 'desc' : 'asc'}.entries) {'k': e.key, 'v': e.value}
      ],
      // Rows-per-page choice (the pager macro GET form): without `per_page` and page — a change goes back to page 1.
      'sizes': [for (final r in _sizes) {'n': r, 'selected': r == onPage}],
      'hidden_per_page': [
        for (final e in {..._current, 'sort': sort, 'dir': descending ? 'desc' : 'asc'}.entries)
          if (e.key != 'per_page') {'k': e.key, 'v': e.value}
      ],
      'per_page_choice': _sizes.isNotEmpty && total > _sizes.first,
      // Header link: the same key → reversed direction, another → its default; page goes back to 1.
      'sort_links': {
        for (final k in _keys)
          k: _address({
            ..._current,
            'sort': k,
            'dir': (k == sort ? !descending : !_ascending.contains(k)) ? 'desc' : 'asc',
          })
      },
    };
  }
}
