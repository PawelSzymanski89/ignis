// FIX-45: pola ustawień czytane przez silnik są walidowane przy zapisie.
import 'package:ignis/engine/config.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  final field = {for (final p in configSections.first.fields) p.key: p};
  String? b(String k, String v) => valueError(field[k]!, v);
  check('strefa: Europe/Warsaw i UTC przechodzą', b('timezone', 'Europe/Warsaw') == null && b('timezone', 'UTC') == null);
  check('strefa: nieznana odrzucona', b('timezone', 'Mars/Olympus') == 'ignis.msg.settings.unknown_zone');
  check('url: https://host przechodzi', b('base_url', 'https://example.com/sklep') == null);
  check('url: http, javascript:, bez hosta, z userinfo — odrzucone', [
    'http://example.com', 'javascript:alert(1)', 'https://', 'example.com', 'https://a@evil.example'
  ].every((v) => b('base_url', v) != null));
  check('pusta wartość nie jest błędem walidatora', b('base_url', '') == null);
  check('stopka: 256 KB odrzucone, krótka przechodzi', b('footer', 'x' * 256 * 1024) != null && b('footer', '© 2026') == null);
}
