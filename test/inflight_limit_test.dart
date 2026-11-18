// HARD-L.3: requests in flight above IGNIS_MAX_INFLIGHT get 503 with Retry-After before routing — no database.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ignis/ignis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

@Page('/v8/x', api: true)
class ApiPage extends PageEngine {}

Future<void> main() async {
  PageRegistry.build();
  check('default limit is 512', Engine.maxInFlight == 512);
  Engine.maxInFlight = 1;
  final hold = Completer<void>(), entered = Completer<void>();
  var handled = 0;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () async {
        handled++;
        if (!entered.isCompleted) entered.complete();
        await hold.future;
        req.response.write('ok');
        await req.response.close();
      }));
  final client = HttpClient();
  Future<HttpClientResponse> get(String path) async => (await client.get('127.0.0.1', server.port, path)).close();

  final first = get('/a');
  await entered.future;
  final second = await get('/b');
  await second.drain<void>();
  check('second request in flight → 503', second.statusCode == 503);
  check('…with Retry-After', second.headers.value(HttpHeaders.retryAfterHeader) != null);
  check('…without reaching the handler', handled == 1);
  final api = await get('/v8/x');
  check('API path → JSON 503', api.statusCode == 503 && api.headers.contentType?.mimeType == 'application/json');
  await api.drain<void>();
  hold.complete();
  final r1 = await first;
  check('the first request finishes normally', r1.statusCode == 200 && await r1.transform(utf8.decoder).join() == 'ok');
  final r3 = await get('/c');
  await r3.drain<void>();
  check('after it finishes the slot is free again', r3.statusCode == 200);
  client.close(force: true);
  await server.close(force: true);
  exit(0);
}
