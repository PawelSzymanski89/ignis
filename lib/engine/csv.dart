// CSV for download from the panel (RFC 4180, `,` separator, `\r\n` rows, UTF-8 BOM for Excel).
// A cell starting with = + - @ tab or CR gets a `'` prefix — the spreadsheet will not run it as a formula
// (CSV injection). Numbers (num) are written as is, so negative values stay numbers.

/// One CSV cell: numbers as is, text quoted when it contains `,` `"` or a newline.
String csvCell(Object? v) {
  if (v == null) return '';
  if (v is num) return v.isFinite ? '$v' : '';
  var s = '$v';
  if (s.isNotEmpty && '=+-@\t\r'.contains(s[0])) s = "'$s";
  return RegExp(r'[",\r\n]').hasMatch(s) ? '"${s.replaceAll('"', '""')}"' : s;
}

/// The whole CSV file: header + rows, with a BOM (Excel recognizes UTF-8 and non-ASCII characters).
String csv(List<String> header, Iterable<List<Object?>> rows) {
  final b = StringBuffer('\uFEFF')..write(header.map(csvCell).join(','))..write('\r\n');
  for (final w in rows) {
    b
      ..write(w.map(csvCell).join(','))
      ..write('\r\n');
  }
  return b.toString();
}
