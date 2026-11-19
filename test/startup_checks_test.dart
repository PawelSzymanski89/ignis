// HARD-L.9: IGNIS_TRUSTED_PROXIES must be set (`none` = deliberately no proxy); backend hosts outside
// loopback without TLS are warned about. No database: the start is cut short by the checks or by the missing DB.
import 'dart:io';

import 'package:ignis/engine/client_ip.dart';
import 'package:ignis/ignis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

/// Child: Ignis.start() with [env] (no database configured) — prints the start-up error.
Future<String> start(Map<String, String> env) async {
  final r = await Process.run(Platform.resolvedExecutable, [Platform.script.toFilePath(), 'start'],
      environment: {'IGNIS_KEY': '0123456789abcdef' * 4, ...env}, includeParentEnvironment: false);
  return '${r.stdout}${r.stderr}';
}

Future<void> main(List<String> a) async {
  if (a.isNotEmpty) {
    try {
      await Ignis.start();
    } catch (e) {
      stdout.writeln('START FAILED: $e');
    }
    exit(0);
  }
  print('IGNIS_TRUSTED_PROXIES:');
  check('unset — refused, the message says what to set', Ignis.trustedProxiesError({})?.contains('none') == true);
  check('empty — refused', Ignis.trustedProxiesError({'IGNIS_TRUSTED_PROXIES': ' '}) != null);
  check('none — accepted', Ignis.trustedProxiesError({'IGNIS_TRUSTED_PROXIES': 'none'}) == null);
  check('an address — accepted', Ignis.trustedProxiesError({'IGNIS_TRUSTED_PROXIES': '10.0.0.0/8'}) == null);
  check('none mixed with addresses — refused',
      Ignis.trustedProxiesError({'IGNIS_TRUSTED_PROXIES': 'none,10.0.0.1'}) != null);
  check('none → no trusted proxies', parseTrustedProxies('none').isEmpty);
  check('a list is parsed', parseTrustedProxies(' 10.0.0.1, ::1 ').join('|') == '10.0.0.1|::1');

  var out = await start({});
  check('Ignis.start without the variable stops with that message',
      out.contains('START FAILED') && out.contains('IGNIS_TRUSTED_PROXIES'));
  out = await start({'IGNIS_TRUSTED_PROXIES': 'none'});
  check('Ignis.start with none gets past the check (stops later, on the missing database)',
      out.contains('START FAILED') && !out.contains('IGNIS_TRUSTED_PROXIES') && out.contains('IGNIS_DB_HOST'));

  print('backend TLS:');
  List<String> w(Map<String, String> env) => Ignis.backendTlsWarnings(env);
  check('everything on loopback — no warning',
      w({'IGNIS_DB_HOST': '127.0.0.1', 'IGNIS_REDIS_HOST': 'localhost', 'IGNIS_S3_HOST': '::1'}).isEmpty);
  final remote = w({'IGNIS_DB_HOST': 'db.internal', 'IGNIS_REDIS_HOST': '10.0.0.5', 'IGNIS_S3_HOST': 's3.internal'});
  check('remote hosts without TLS — one warning each',
      remote.length == 3 && remote[0].contains('IGNIS_DB_SSL') && remote[1].contains('IGNIS_REDIS_TLS') && remote[2].contains('IGNIS_S3_SSL'));
  check('remote hosts with TLS — no warning', w({
    'IGNIS_DB_HOST': 'db.internal', 'IGNIS_DB_SSL': 'verify-full',
    'IGNIS_REDIS_HOST': '10.0.0.5', 'IGNIS_REDIS_TLS': '1',
    'IGNIS_S3_HOST': 's3.internal', 'IGNIS_S3_SSL': '1',
  }).isEmpty);
  check('IGNIS_DB_SSL=disable counts as off', w({'IGNIS_DB_HOST': '10.1.1.1', 'IGNIS_DB_SSL': 'disable'}).length == 1);
  check('no S3 configured — nothing about S3', w({'IGNIS_DB_HOST': '127.0.0.1'}).isEmpty);
  out = await start({'IGNIS_TRUSTED_PROXIES': 'none', 'IGNIS_DB_HOST': 'db.invalid', 'IGNIS_DB_PASS': 'x'});
  check('Ignis.start prints the warning', out.contains('IGNIS_DB_SSL'));
}
