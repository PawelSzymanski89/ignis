// HARD-L.13.4: bodies of `api: true` routes share one node budget (IGNIS_API_BODY_BUDGET_MB), like multipart uploads:
// bytes read on the wire and inflated from gzip are reserved as they come, released when the request ends (also when
// the client drops the connection or the request deadline ends a hanging body). Over the budget → 503 with Retry-After;
// a value other than an integer ≥ 1 stops the node. No database (technical + noDb route).
// Run: dart run test/api_body_budget_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ignis/ignis.dart';

import 'registry_helper.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

var handled = 0;

@Page('/v7/budget', api: true, technical: true, noDb: true, methods: ['POST'], maxBody: 4 * 1024 * 1024)
class BudgetApi extends PageEngine {
  @override
  Future<bool> processData() async {
    handled++;
    return respond(200, {'n': body.length});
  }
}

const mb = 1024 * 1024;

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    final r = await Process.run(Platform.resolvedExecutable, [Platform.script.toFilePath(), 'child'],
        environment: {'IGNIS_API_BODY_BUDGET_MB': '3'});
    stdout.write(r.stdout);
    stderr.write(r.stderr);
    exit(r.exitCode);
  }
  PageRegistry.build(testRegistry(pages: [
    testPage(
        const Page('/v7/budget', api: true, technical: true, noDb: true, methods: ['POST'], maxBody: 4 * 1024 * 1024),
        BudgetApi.new)
  ]));
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  // what the server answered (status, Retry-After) — the client may not get to read it, see [rejected]
  final served = <(int, String?)>[];
  server.listen((req) async {
    await Engine.guarded(req, () => dispatch(req, const []));
    served.add((req.response.statusCode, req.response.headers.value(HttpHeaders.retryAfterHeader)));
  });

  // raw socket: the body can stop half-way and the connection can be dropped
  Future<Socket> start(int length, int sent, {bool gz = false}) async {
    final s = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    s.write('POST /v7/budget HTTP/1.1\r\nHost: localhost\r\nContent-Length: $length\r\n'
        '${gz ? 'Content-Encoding: gzip\r\n' : ''}Connection: close\r\n\r\n');
    s.add(List.filled(sent, 0x61));
    await s.flush();
    return s;
  }

  // the answer is read while the body is still being written: an early 503 closes the connection mid-body
  Future<String> finish(Socket s, List<int> rest) async {
    final got = <int>[];
    final read = s.listen(got.addAll).asFuture<void>().then((_) {}, onError: (_) {}); // reset after an early answer
    try {
      s.add(rest);
      await s.flush();
    } catch (_) {}
    await read;
    return latin1.decode(got);
  }

  Future<String> post(List<int> body, {bool gz = false}) async => finish(await start(body.length, 0, gz: gz), body);
  int status(String response) => response.isEmpty ? -1 : int.parse(response.split(' ')[1]);
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 400));

  // A body over the budget: the server must answer 503 + Retry-After. The client normally reads it; a connection
  // reset while it is still writing the body (the server closes after the early answer) is accepted only when the
  // server did answer that very request with 503 + Retry-After — never a reset alone.
  Future<void> rejected(String what, List<int> body, {bool gz = false}) async {
    final before = served.length;
    final r = await post(body, gz: gz);
    for (var i = 0; i < 50 && served.length == before; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final s = served.length > before ? served[before] : null;
    check('$what → the server answered 503 with Retry-After', s != null && s.$1 == 503 && s.$2 != null);
    check('…and the client got that 503 with Retry-After, or a reset while still sending the body (got ${status(r)})',
        status(r) == -1 || (status(r) == 503 && r.toLowerCase().contains('retry-after:')));
  }

  final a = await start((1.5 * mb).round(), (1.2 * mb).round());
  final b = await start((1.5 * mb).round(), (1.2 * mb).round());
  await settle();
  await rejected('a third body over the shared budget', List.filled(mb, 0x61));
  final ra = await finish(a, List.filled((0.3 * mb).round(), 0x61));
  final rb = await finish(b, List.filled((0.3 * mb).round(), 0x61));
  check('the two bodies within the budget finish normally', status(ra) == 200 && status(rb) == 200);
  check('the rejected one never reached the page', handled == 2);
  check('after they finish the whole budget is free again (2.9 MB → 200)', status(await post(List.filled((2.9 * mb).round(), 0x61))) == 200);

  final d = await start(2 * mb, (1.5 * mb).round());
  await settle();
  d.destroy();
  await settle();
  check('a client dropping the connection mid-body releases its share', status(await post(List.filled((2.9 * mb).round(), 0x61))) == 200);

  final bomb = gzip.encode(List.filled(4 * mb - 10, 0x61));
  final held = await start((1.5 * mb).round(), (1.2 * mb).round());
  await settle();
  await rejected('inflated gzip bytes count against the budget too', bomb, gz: true);
  check('…small on the wire', bomb.length < 64 * 1024);
  await finish(held, List.filled((0.3 * mb).round(), 0x61));
  check('IGNIS_API_BODY_BUDGET_MB is read at start-up', Engine.apiBodyBudget == 3 * mb);

  // a client that stops sending and keeps the connection open: the request deadline ends it and frees its share
  Engine.requestDeadline = const Duration(seconds: 4);
  final hung = await start((2.5 * mb).round(), 2 * mb);
  await settle();
  await rejected('while the body hangs its share is held (1.5 MB)', List.filled((1.5 * mb).round(), 0x61));
  final closed = hung.drain<void>().then((_) => true, onError: (_) => true).timeout(const Duration(seconds: 8), onTimeout: () => false);
  check('the deadline closes the hanging connection', await closed);
  await settle();
  check('…and releases its share (2.9 MB → 200)', status(await post(List.filled((2.9 * mb).round(), 0x61))) == 200);
  hung.destroy();

  Object? e;
  for (final bad in ['0', '-1', 'lots', '']) {
    e = null;
    try {
      Engine.parseApiBodyBudget(bad);
    } catch (x) {
      e = x;
    }
    check('IGNIS_API_BODY_BUDGET_MB=$bad → StateError', e is StateError && '$e'.contains('IGNIS_API_BODY_BUDGET_MB'));
  }
  check('IGNIS_API_BODY_BUDGET_MB unset → 64 MB, " 8 " → 8 MB',
      Engine.parseApiBodyBudget(null) == 64 * mb && Engine.parseApiBodyBudget(' 8 ') == 8 * mb);
  await server.close(force: true);
  print('\nALL PASSED');
  exit(0);
}
