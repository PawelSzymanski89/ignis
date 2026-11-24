// HARD-L.9: IGNIS_TRUSTED_PROXIES must be set (`none` = deliberately no proxy); backend hosts outside
// loopback without TLS are warned about. No database: the start is cut short by the checks or by the missing DB.
import 'dart:io';

import 'package:ignis/engine/client_ip.dart';
import 'package:ignis/ignis.dart';
import 'package:ignis/ignis_registry.g.dart';

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
      await Ignis.start(registry: ignisRegistry);
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
  check('NONE / None — accepted, case-insensitive', Ignis.trustedProxiesError({'IGNIS_TRUSTED_PROXIES': 'NONE'}) == null &&
      parseTrustedProxies(' None ').isEmpty);
  check('IPv6 and IPv6 CIDR — accepted',
      Ignis.trustedProxiesError({'IGNIS_TRUSTED_PROXIES': '::1, fd00::/8, 10.0.0.1/32'}) == null);
  for (final bad in ['0.0.0.0/0', '::/0', '10.0.0.0/33', 'proxy.local', '10.0.0.1/x', '10.0.0.1/8/8', '10.0.0']) {
    final e = Ignis.trustedProxiesError({'IGNIS_TRUSTED_PROXIES': '10.0.0.5,$bad'});
    check('`$bad` — refused, the entry is named', e != null && e.contains('`$bad`'));
  }
  check('none → no trusted proxies', parseTrustedProxies('none').isEmpty);
  check('a list is parsed', parseTrustedProxies(' 10.0.0.1, ::1 ').join('|') == '10.0.0.1|::1');

  var out = await start({});
  check('Ignis.start without the variable stops with that message',
      out.contains('START FAILED') && out.contains('IGNIS_TRUSTED_PROXIES'));
  out = await start({'IGNIS_TRUSTED_PROXIES': 'none'});
  check('Ignis.start with none gets past the check (stops later, on the missing database)',
      out.contains('START FAILED') && !out.contains('IGNIS_TRUSTED_PROXIES') && out.contains('IGNIS_DB_HOST'));

  out = await start({'IGNIS_TRUSTED_PROXIES': 'none', 'IGNIS_MAX_INFLIGHT': '0'});
  check('IGNIS_MAX_INFLIGHT=0 stops the start', out.contains('START FAILED') && out.contains('IGNIS_MAX_INFLIGHT'));
  out = await start({'IGNIS_TRUSTED_PROXIES': 'none', 'IGNIS_API_BODY_BUDGET_MB': '0'});
  check('IGNIS_API_BODY_BUDGET_MB=0 stops the start',
      out.contains('START FAILED') && out.contains('IGNIS_API_BODY_BUDGET_MB'));

  print('backend TLS:');
  // SEC-040.6: missing IGNIS_NODE and a remote Redis without a password are warned about
  final n = Ignis.nodeWarnings;
  check('no IGNIS_NODE → warning', n({}).single.contains('IGNIS_NODE'));
  check('remote Redis without IGNIS_REDIS_PASS → warning',
      n({'IGNIS_NODE': 'a', 'IGNIS_REDIS_HOST': '10.0.0.5'}).single.contains('IGNIS_REDIS_PASS'));
  check('IGNIS_NODE set, Redis on loopback or with a password → no warning',
      n({'IGNIS_NODE': 'a', 'IGNIS_REDIS_HOST': '127.0.0.1'}).isEmpty &&
          n({'IGNIS_NODE': 'a', 'IGNIS_REDIS_HOST': '10.0.0.5', 'IGNIS_REDIS_PASS': 'x'}).isEmpty);
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
  final req = w({'IGNIS_DB_HOST': 'db.internal', 'IGNIS_DB_SSL': 'require'});
  check('IGNIS_DB_SSL=require on a remote host — warning about the unverified certificate',
      req.length == 1 && req.single.contains('not verified') && req.single.contains('verify-full'));
  check('IGNIS_DB_SSL=require on loopback — no warning', w({'IGNIS_DB_HOST': '127.0.0.1', 'IGNIS_DB_SSL': 'require'}).isEmpty);
  out = await start({'IGNIS_TRUSTED_PROXIES': '0.0.0.0/0'});
  check('Ignis.start with IGNIS_TRUSTED_PROXIES=0.0.0.0/0 stops', out.contains('START FAILED') && out.contains('0.0.0.0/0'));
  out = await start({'IGNIS_TRUSTED_PROXIES': 'NONE'});
  check('Ignis.start with NONE gets past the check', out.contains('START FAILED') && out.contains('IGNIS_DB_HOST'));
  check('no S3 configured — nothing about S3', w({'IGNIS_DB_HOST': '127.0.0.1'}).isEmpty);
  out = await start({'IGNIS_TRUSTED_PROXIES': 'none', 'IGNIS_DB_HOST': 'db.invalid', 'IGNIS_DB_PASS': 'x'});
  check('Ignis.start prints the warning', out.contains('IGNIS_DB_SSL'));
}
