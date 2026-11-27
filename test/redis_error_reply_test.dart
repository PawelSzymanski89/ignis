// IGNIS-054.2: an error reply from the server (-ERR, -NOAUTH …) reaches the caller and keeps the connection; only a
// timeout or a socket error drops it. Before, every failed command opened a new TCP connection (~1000 of them in
// permissions_invalidation_retry_test while Redis refused DEL).
// No database, no real Redis: the parent runs a tiny RESP server and re-runs this file as a child pointed at it
// (IGNIS_REDIS_* are read from the process environment).
import 'dart:convert';
import 'dart:io';

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
      exit(1);
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
  stderr.write(r.stderr);
  check('child passed', r.exitCode == 0);
  print('\nALL PASSED');
}

Future<void> _child() async {
  const n = 50;
  var errors = 0;
  Object? first;
  for (var i = 0; i < n; i++) {
    try {
      await Redis.cmd(['FAIL']);
    } catch (e) {
      errors++;
      first ??= e;
    }
  }
  check('every error reply reaches the caller ($errors/$n)', errors == n);
  check('the error carries the server message ($first)', '$first'.contains('ERR nope'));
  check('$n error replies → one connection (got ${await Redis.cmd(['CONNS'])})', await Redis.cmd(['CONNS']) == 1);

  try {
    await Redis.cmd(['KILL']); // the server destroys the socket without a reply
  } catch (_) {}
  Object? after;
  for (var i = 0; i < 3 && after == null; i++) {
    try {
      after = await Redis.cmd(['PING']);
    } catch (_) {}
  }
  check('after a dropped socket the next call reconnects ($after)', after == 'PONG');
  check('… on a second connection', await Redis.cmd(['CONNS']) == 2);
  exit(0);
}

/// PING, FAIL (-ERR nope), CONNS (connections accepted so far), KILL (destroy this socket, no reply).
Future<ServerSocket> _fakeRedis() async {
  var conns = 0;
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((c) {
    conns++;
    c.done.catchError((_) {});
    var buf = '';
    c.cast<List<int>>().transform(utf8.decoder).listen((chunk) {
      buf += chunk;
      while (true) {
        final parsed = _parse(buf);
        if (parsed == null) break;
        buf = buf.substring(parsed.$2);
        switch (parsed.$1.first.toUpperCase()) {
          case 'PING':
            c.write('+PONG\r\n');
          case 'CONNS':
            c.write(':$conns\r\n');
          case 'KILL':
            c.destroy();
            return;
          default:
            c.write('-ERR nope\r\n');
        }
      }
    }, onError: (_) {}, onDone: c.destroy);
  });
  return s;
}

/// One RESP array of bulk strings at the start of [b], with its length, or null if incomplete.
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
