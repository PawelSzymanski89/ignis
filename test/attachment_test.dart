// Test PageEngine.zalacznik — pobranie tekstu jako pliku, bez bazy.
import '../lib/engine/page_engine.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

class _TestPage extends PageEngine {}

void main() {
  final s = _TestPage();
  final result = s.attachment('konfig-a.json', '{"v":1}', type: 'application/json; charset=utf-8');
  check('zwraca false (bez renderu)', result == false);
  check('Content-Disposition attachment',
      s.headers['Content-Disposition'] == 'attachment; filename="konfig-a.json"');
  check('Content-Type ustawiony', s.contentType == 'application/json; charset=utf-8');
  check('treść w buforze', s.outBuffer.toString() == '{"v":1}');
  check('no-store', s.headers['Cache-Control'] == 'no-store');

  final z = _TestPage()..attachment('a"\r\nX-Zly: 1.txt', 'x');
  check('nazwa bez cudzysłowu i CRLF',
      z.headers['Content-Disposition'] == 'attachment; filename="a___X-Zly__1.txt"');
}
