// SEC-040.5: /assets/ answers `immutable` only when ?v= equals this node's content digest, otherwise no-cache.
// No database. Run: dart run test/asset_cache_test.dart
import 'dart:io';

import 'package:ignis/engine/ignis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('asset_cache');
  File('${dir.path}/a.js').writeAsStringSync('console.log(1)');
  final v = RegExp(r'\?v=([0-9a-f]{10})"').firstMatch(versionAssets('<script src="/assets/a.js"></script>', [dir.path]))![1]!;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => dispatch(req, [dir.path]));
  final client = HttpClient();
  Future<String?> cache(String q) async {
    final r = await (await client.get('127.0.0.1', server.port, '/assets/a.js$q')).close();
    await r.drain<void>();
    return r.headers.value(HttpHeaders.cacheControlHeader);
  }

  check('?v=<own digest> → immutable', await cache('?v=$v') == 'public, max-age=31536000, immutable');
  check('?v=<other digest> → no-cache', await cache('?v=0123456789') == 'no-cache');
  check('no ?v → no-cache', await cache('') == 'no-cache');
  client.close(force: true);
  await server.close(force: true);
  dir.deleteSync(recursive: true);
  print('\nALL PASSED');
}
