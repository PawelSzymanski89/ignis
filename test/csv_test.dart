// Test komorkaCsv/csv — cytowanie RFC 4180, ochrona przed formułami, liczby, BOM.
import '../lib/engine/csv.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  check('zwykły tekst bez cudzysłowu', csvCell('purchase') == 'purchase');
  check('przecinek i cudzysłów → cytowanie, "" w środku', csvCell('a,"b"') == '"a,""b"""');
  check('nowa linia → cytowanie', csvCell('a\nb') == '"a\nb"');
  check('formuła =, +, -, @ dostaje prefiks apostrofu',
      csvCell('=SUM(A1)') == "'=SUM(A1)" && csvCell('+1') == "'+1" && csvCell('-x') == "'-x" && csvCell('@a') == "'@a");
  check('formuła z przecinkiem: prefiks i cytowanie', csvCell('=A1,B1') == '"\'=A1,B1"');
  check('liczby wprost (także ujemne), null i NaN puste',
      csvCell(-12.5) == '-12.5' && csvCell(3) == '3' && csvCell(null) == '' && csvCell(double.nan) == '');
  final p = csv(['kampania', 'CR'], [['Promo, zima', 0.08], ['x', null]]);
  check('plik: BOM, nagłówek, CRLF', p == '\uFEFFkampania,CR\r\n"Promo, zima",0.08\r\nx,\r\n');
}
