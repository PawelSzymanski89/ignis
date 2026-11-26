// IGNIS-050.5: a permission-cache invalidation that fails (Redis blip) is logged to stderr ONCE per burst and
// retried until it goes through — a revoked permission must not live for the whole 15 min TTL.
// No database, no real Redis: the parent runs a tiny RESP server whose DEL can be switched to fail, and re-runs
// this file as a child pointed at it (IGNIS_REDIS_* are read from the process environment).
import 'dart:convert';
import 'dart:io';

import 'package:ignis/engine/permissions.dart';
import 'package:ignis/engine/redis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  if (Platform.environment['IGNIS_TEST_CHILD'] == '1') return _child();
  final server = await _fakeRedis();
  final r = await Process.run(Platform.resolvedExecutable, ['run', Platform.script.toFilePath()], environment: {
    'IGNIS_TEST_CHILD': '1',
    'IGNIS_REDIS_HOST': '127.0.0.1',
    'IGNIS_REDIS_PORT': '${server.port}',
  });
  await server.close();
  stdout.write(r.stdout);
  final err = '${r.stderr}';
  check('child passed', r.exitCode == 0);
  check('the failure is logged to stderr, once for two failures in a row',
      'cache invalidation failed'.allMatches(err).length == 1);
}

Future<void> _child() async {
  await Redis.setEx('perm:alice', '{"a":["x"],"d":[],"p":[]}', 900);
  await Redis.setEx('perm:bob', '{"a":["x"],"d":[],"p":[]}', 900);
  await Redis.cmd(['TESTDOWN']);
  Object? e1, e2;
  try {
    await Permissions.invalidateMany(['alice']); // no open transaction → the error reaches the caller
  } catch (e) {
    e1 = e;
  }
  try {
    await Permissions.invalidateMany(['bob']);
  } catch (e) {
    e2 = e;
  }
  check('a failed invalidation still reaches the caller', e1 != null && e2 != null);
  check('the stale entry is there while Redis refuses DEL', await Redis.get('perm:alice') != null);
  await Redis.cmd(['TESTUP']);
  final until = DateTime.now().add(const Duration(seconds: 6));
  while (DateTime.now().isBefore(until) &&
      (await Redis.get('perm:alice') != null || await Redis.get('perm:bob') != null)) {
    await Future.delayed(const Duration(milliseconds: 200));
  }
  check('once Redis takes DEL again, the retry drops the stale entries',
      await Redis.get('perm:alice') == null && await Redis.get('perm:bob') == null);
  exit(0); // the retry loops are done; nothing else to wait for
}

/// GET/SET/DEL over RESP; TESTDOWN makes DEL answer an error until TESTUP.
Future<ServerSocket> _fakeRedis() async {
  final data = <String, String>{};
  var down = false;
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((c) {
    c.done.catchError((_) {}); // the child exits without closing its connection
    var buf = '';
    c.cast<List<int>>().transform(utf8.decoder).listen((chunk) {
      buf += chunk;
      while (true) {
        final parsed = _parse(buf);
        if (parsed == null) break;
        buf = buf.substring(parsed.$2);
        final a = parsed.$1;
        switch (a.first.toUpperCase()) {
          case 'TESTDOWN':
            down = true;
            c.write('+OK\r\n');
          case 'TESTUP':
            down = false;
            c.write('+OK\r\n');
          case 'SET':
            data[a[1]] = a[2];
            c.write('+OK\r\n');
          case 'GET':
            final v = data[a[1]];
            c.write(v == null ? '\$-1\r\n' : '\$${utf8.encode(v).length}\r\n$v\r\n');
          case 'DEL':
            if (down) {
              c.write('-ERR down\r\n');
            } else {
              final n = a.skip(1).where((k) => data.remove(k) != null).length;
              c.write(':$n\r\n');
            }
          default:
            c.write('-ERR unknown\r\n');
        }
      }
    }, onError: (_) {}); // the child exits without closing its connection
  });
  return s;
}

/// One RESP array of bulk strings from the front of [b], with the length consumed, or null if incomplete.
(List<String>, int)? _parse(String b) {
  if (!b.startsWith('*')) return null;
  var i = b.indexOf('\r\n');
  if (i < 0) return null;
  final n = int.parse(b.substring(1, i));
  var pos = i + 2;
  final out = <String>[];
  for (var k = 0; k < n; k++) {
    i = b.indexOf('\r\n', pos);
    if (i < 0) return null;
    final len = int.parse(b.substring(pos + 1, i));
    final start = i + 2;
    if (b.length < start + len + 2) return null;
    out.add(b.substring(start, start + len));
    pos = start + len + 2;
  }
  return (out, pos);
}
