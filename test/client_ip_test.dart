// Adres klienta do limitów — X-Forwarded-For tylko od zaufanego proxy, od prawej (audyt A#2).
import '../lib/engine/client_ip.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  const proxy = ['10.0.0.0/8', '173.245.48.0/20', '2400:cb00::/32', '127.0.0.1'];
  final cases = <(String, String, String?, List<String>, String)>[
    ('bez zaufanych XFF ignorowany', '1.2.3.4', '9.9.9.9', const [], '1.2.3.4'),
    ('połączenie spoza proxy — XFF ignorowany', '5.6.7.8', '9.9.9.9', proxy, '5.6.7.8'),
    ('z proxy — jedyny wpis', '10.1.2.3', '9.9.9.9', proxy, '9.9.9.9'),
    ('podrobiony pierwszy wpis nie wygrywa', '10.1.2.3', '6.6.6.6, 9.9.9.9', proxy, '9.9.9.9'),
    ('łańcuch proxy pomijany od prawej', '127.0.0.1', '6.6.6.6, 9.9.9.9, 173.245.50.1, 10.0.0.5', proxy, '9.9.9.9'),
    ('IPv6 w CIDR', '10.0.0.1', '2a01::1, 2400:cb00::7', proxy, '2a01::1'),
    ('brak XFF od proxy — adres połączenia', '10.0.0.1', null, proxy, '10.0.0.1'),
    ('wszystkie zaufane — najdalszy', '10.0.0.1', '10.9.9.9, 10.0.0.2', proxy, '10.9.9.9'),
    ('IPv4 zmapowany na IPv6', '::ffff:10.0.0.1', '9.9.9.9', proxy, '9.9.9.9'),
    ('spoza maski /20', '173.245.64.1', '9.9.9.9', proxy, '173.245.64.1'),
    ('śmieć w liście zaufanych nie psuje', '10.0.0.1', '9.9.9.9', const ['zle/99', 'x', '10.0.0.1'], '9.9.9.9'),
  ];
  for (final (description, fieldsCount, xff, trusted, expected) in cases) {
    final w = clientAddress(fieldsCount, xff, trusted);
    check('$description ($w)', w == expected);
  }

  print('klucz limitów (FIX-31):');
  check('IPv4 bez zmian', rateLimitAddress('9.9.9.9') == '9.9.9.9');
  check('IPv6 przycięty do /64', rateLimitAddress('2a01:db8:1:2:aaaa::1') == '2a01:db8:1:2::/64');
  check('ta sama /64 — ten sam klucz', rateLimitAddress('2a01:db8:1:2::ffff') == rateLimitAddress('2a01:db8:1:2:1:2:3:4'));
  check('inna /64 — inny klucz', rateLimitAddress('2a01:db8:1:3::1') != rateLimitAddress('2a01:db8:1:2::1'));
  check('śmieć bez zmian', rateLimitAddress('x') == 'x' && rateLimitAddress('') == '');

  print('sonda zdrowia (SEC-B-2):');
  check('loopback v4', probeAllowed('127.0.0.1', null, const []));
  check('loopback v6 i zmapowany', probeAllowed('::1', null, const []) && probeAllowed('::ffff:127.0.0.1', null, const []));
  check('zaufane proxy', probeAllowed('10.1.2.3', null, proxy));
  check('obcy adres — nie (Host nie ma znaczenia)', !probeAllowed('1.1.1.1', null, proxy));
  check('klient przez proxy (XFF) — nie', !probeAllowed('10.1.2.3', '9.9.9.9', proxy));
  check('pusty adres — nie', !probeAllowed('', null, proxy));
  print('ostrzeżenie o pustym IGNIS_TRUSTED_PROXIES (FIX-11):');
  check('XFF od loopbacku bez zaufanych — ostrzega', proxyWarning('127.0.0.1', '9.9.9.9', const []) != null);
  check('XFF od 10/8, 172.16/12, 192.168/16, fd00::/8 — ostrzega',
      ['10.0.0.5', '172.20.0.2', '192.168.1.1', 'fd00::1', '::ffff:10.0.0.5'].every((p) => proxyWarning(p, '9.9.9.9', const []) != null));
  check('publiczny adres z XFF — nie (to nie nasze proxy)', proxyWarning('8.8.8.8', '9.9.9.9', const []) == null);
  check('bez XFF — nie', proxyWarning('127.0.0.1', null, const []) == null);
  check('ustawione proxy — nie', proxyWarning('127.0.0.1', '9.9.9.9', const ['127.0.0.1']) == null);
}
