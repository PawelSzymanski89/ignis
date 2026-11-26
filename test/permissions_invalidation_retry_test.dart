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
  if (Platform.environment['IGNIS_TEST_CHILD'] == '1') {
    try {
      await _child();
    } catch (e) {
      print(e);
      exit(1); // pending retry timers would keep a failed child alive
    }
    return;
  }
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
  check('the failure is logged to stderr, once for a burst of failures',
      'cache invalidation failed'.allMatches(err).length == 1);
  check('keys over the retry queue limit are logged', err.contains('invalidation retry queue full'));
}

Future<void> _child() async {
  await Redis.setEx('perm:{alice}', '{"a":["x"],"d":[],"p":[]}', 900);
  await Redis.setEx('perm:{bob}', '{"a":["x"],"d":[],"p":[]}', 900);
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
  check('the stale entry is there while Redis refuses DEL', await Redis.get('perm:{alice}') != null);

  // IGNIS-051.2: 1000 failed invalidations of one key = one queue entry, one loop — not 1000 loops each sending DEL
  await Redis.setEx('perm:{carol}', '{"a":["x"],"d":[],"p":[]}', 900);
  for (var i = 0; i < 1000; i++) {
    try {
      await Permissions.invalidateMany(['carol']);
    } catch (_) {}
  }
  await Redis.cmd(['TESTRESET']);
  await Future.delayed(const Duration(milliseconds: 3500));
  final dels = await Redis.cmd(['TESTCOUNT']) as int;
  check('1000 failed invalidations of one key → a handful of retry DELs in 3.5 s (got $dels)', dels <= 15);

  // distinct keys: the queue is bounded (limit 10000)
  final many = [for (var i = 0; i < 12000; i++) 'u$i'];
  try {
    await Permissions.invalidateMany(many);
  } catch (_) {}
  await Redis.cmd(['TESTRESET']);
  // poll until one retry round is through (10000 EVALs to the fake take a few seconds). The loop may be asleep in
  // its backoff (up to retryMax after the failures above), so the window covers a whole backoff, whatever its phase.
  var distinct = 0;
  final roundBy = DateTime.now().add(Permissions.retryMax + const Duration(seconds: 15));
  while (DateTime.now().isBefore(roundBy)) {
    await Future.delayed(const Duration(milliseconds: 100));
    final d = await Redis.cmd(['TESTDISTINCT']) as int;
    if (d > 0 && d == distinct) break;
    distinct = d;
  }
  check('the retry queue holds at most 10000 keys (retried $distinct distinct)', distinct > 0 && distinct <= 10000);

  await Redis.cmd(['TESTUP']);
  final until = DateTime.now().add(const Duration(seconds: 40));
  while (DateTime.now().isBefore(until) &&
      (await Redis.get('perm:{alice}') != null ||
          await Redis.get('perm:{bob}') != null ||
          await Redis.get('perm:{carol}') != null)) {
    await Future.delayed(const Duration(milliseconds: 200));
  }
  check('once Redis takes DEL again, the retry drops the stale entries',
      await Redis.get('perm:{alice}') == null &&
          await Redis.get('perm:{bob}') == null &&
          await Redis.get('perm:{carol}') == null);
  exit(0); // the retry loops are done; nothing else to wait for
}

/// GET/SET/DEL/EVAL (invalidation script, as DEL of KEYS[1]) over RESP; TESTDOWN makes DEL answer an error until TESTUP; TESTCOUNT / TESTDISTINCT = DEL commands
/// / distinct DEL'd keys since TESTRESET.
Future<ServerSocket> _fakeRedis() async {
  final data = <String, String>{};
  var down = false;
  var dels = 0; // DEL commands since TESTRESET
  final delKeys = <String>{};
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((c) {
    c.done.catchError((_) {}); // the child exits without closing its connection
    var buf = '';
    c.cast<List<int>>().transform(utf8.decoder).listen((chunk) {
      buf += chunk;
      var at = 0; // parse by offset, cut once — cutting per command is quadratic on a burst of 10000 EVALs
      while (true) {
        final parsed = _parse(buf, at);
        if (parsed == null) break;
        at = parsed.$2;
        final a = parsed.$1;
        switch (a.first.toUpperCase()) {
          case 'TESTDOWN':
            down = true;
            c.write('+OK\r\n');
          case 'TESTUP':
            down = false;
            c.write('+OK\r\n');
          case 'TESTRESET':
            dels = 0;
            delKeys.clear();
            c.write('+OK\r\n');
          case 'TESTCOUNT':
            c.write(':$dels\r\n');
          case 'TESTDISTINCT':
            c.write(':${delKeys.length}\r\n');
          case 'SET':
            data[a[1]] = a[2];
            c.write('+OK\r\n');
          case 'GET':
            final v = data[a[1]];
            c.write(v == null ? '\$-1\r\n' : '\$${utf8.encode(v).length}\r\n$v\r\n');
          case 'DEL' || 'EVAL':
            // EVAL = the invalidation script (KEYS[1] = the cache entry): counted and failed like DEL
            final keys = a.first.toUpperCase() == 'EVAL' ? [a[3]] : a.skip(1).toList();
            dels++;
            delKeys.addAll(keys);
            if (down) {
              c.write('-ERR down\r\n');
            } else {
              final n = keys.where((k) => data.remove(k) != null).length;
              c.write(':$n\r\n');
            }
          default:
            c.write('-ERR unknown\r\n');
        }
      }
      buf = buf.substring(at);
    }, onError: (_) {}); // the child exits without closing its connection
  });
  return s;
}

/// One RESP array of bulk strings at [from] in [b], with the end offset, or null if incomplete.
(List<String>, int)? _parse(String b, int from) {
  if (!b.startsWith('*', from)) return null;
  var i = b.indexOf('\r\n', from);
  if (i < 0) return null;
  final n = int.parse(b.substring(from + 1, i));
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
