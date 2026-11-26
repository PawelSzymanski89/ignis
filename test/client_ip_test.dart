// Adres klienta do limitów — X-Forwarded-For tylko od zaufanego proxy, od prawej (audyt A#2).
import 'dart:io';

import '../lib/engine/client_ip.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
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

  print('klucz limitów — równoważne zapisy (IGNIS-050.10):');
  bool same(List<String> xs) => xs.map(rateLimitAddress).toSet().length == 1;
  check('IPv4 i IPv4-mapped (kropkowy, hex, wielkie litery, pełny zapis) — jeden klucz 10.0.0.1',
      same(['10.0.0.1', '::ffff:10.0.0.1', '::FFFF:10.0.0.1', '::ffff:0a00:0001', '::ffff:a00:1',
            '0:0:0:0:0:ffff:a00:1', '0000:0000:0000:0000:0000:ffff:0a00:0001']) &&
          rateLimitAddress('::ffff:0a00:0001') == '10.0.0.1');
  check('różne IPv4-mapped — różne klucze (nie wspólne ::/64)',
      rateLimitAddress('::ffff:0a00:0001') != rateLimitAddress('::ffff:0a00:0002'));
  check('różne IPv4 — różne klucze', rateLimitAddress('10.0.0.1') != rateLimitAddress('10.0.0.2'));
  check('IPv6: pełny, skrócony, wielkie litery, zera wiodące, zona — jeden klucz',
      same(['2001:db8:1:2::1', '2001:0db8:0001:0002:0000:0000:0000:0001', '2001:DB8:1:2::1', '2001:db8:1:2:0:0:0:1',
            '2001:db8:1:2::1%eth0', '[2001:db8:1:2::1]', '[2001:db8:1:2::1]:443']));
  check('IPv4 z portem (XFF od niektórych proxy) — jak bez portu', rateLimitAddress('9.9.9.9:5555') == '9.9.9.9');
  check('ten sam /64 — ten sam klucz; inny /64 — inny',
      same(['2001:db8:1:2::1', '2001:db8:1:2:ffff:ffff:ffff:ffff']) &&
          rateLimitAddress('2001:db8:1:2::1') != rateLimitAddress('2001:db8:1:3::1'));
  check('zona link-local nie zmienia klucza', same(['fe80::1%eth0', 'fe80::1%en1', 'fe80::1']));
  check('XFF z zaufanego proxy w zapisie zmapowanym — jak gołe IPv4',
      rateLimitAddress(clientAddress('10.1.2.3', '::FFFF:9.9.9.9', proxy)) == rateLimitAddress('9.9.9.9') &&
          rateLimitAddress(clientAddress('::ffff:10.1.2.3', '9.9.9.9', proxy)) == '9.9.9.9');

  print('connectionInfo.remoteAddress z prawdziwego gniazda (dual-stack):');
  final server = await HttpServer.bind(InternetAddress.anyIPv6, 0, v6Only: false);
  final seen = <String>[];
  server.listen((r) {
    seen.add(r.connectionInfo!.remoteAddress.address);
    r.response.close();
  });
  final client = HttpClient();
  for (final host in ['127.0.0.1', '[::1]']) {
    await (await (await client.getUrl(Uri.parse('http://$host:${server.port}/'))).close()).drain<void>();
  }
  client.close(force: true);
  await server.close(force: true);
  print('  adresy z gniazda: $seen');
  check('klient v4 na gnieździe v6 — klucz jak dla 127.0.0.1', rateLimitAddress(seen[0]) == '127.0.0.1');
  check('klient ::1 — klucz ::/64', rateLimitAddress(seen[1]) == '::/64');
  check('z gniazda bez proxy — klucz jak z adresu', rateLimitAddress(clientAddress(seen[0], '6.6.6.6', const [])) == '127.0.0.1');

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
