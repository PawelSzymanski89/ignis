// IGNIS-052.2 [Ś-2]: /files sends Content-Length from S3, so a stream cut mid-way
// drops the connection instead of returning a truncated body under 200.
// No database and no MinIO: ServeFilePage.read swapped for a fake stream; technical route (no tenant lookup).
// Run: dart run test/serve_file_length_test.dart
import 'dart:async';
import 'dart:io';

import 'package:ignis/ignis.dart';
import 'package:minio/minio.dart' show MinioByteStream;

import 'registry_helper.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

const _key = '2026/08/0123456789abcdef0123456789abcdef.png';

Future<(int?, int, Object?)> fetch(int port) async {
  final client = HttpClient();
  try {
    final r = await (await client.get('127.0.0.1', port, '/files?k=$_key')).close();
    var got = 0;
    Object? error;
    try {
      await for (final c in r) {
        got += c.length;
      }
    } catch (e) {
      error = e;
    }
    return (r.statusCode, got, error);
  } catch (e) {
    return (null, 0, e);
  } finally {
    client.close(force: true);
  }
}

Future<void> main() async {
  PageRegistry.build(testRegistry(pages: [
    testPage(const Page('/files', technical: true, noDb: true), ServeFilePage.new),
  ]));
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () => Engine.handle(req)));

  // complete object: 100 bytes declared, 100 sent
  ServeFilePage.read = (k, s) async =>
      MinioByteStream.fromStream(stream: Stream.value(List.filled(100, 1)), contentLength: 100);
  final (okStatus, okGot, okErr) = await fetch(server.port);
  check('complete object → 200 with 100 bytes, no error', okStatus == 200 && okGot == 100 && okErr == null);

  // S3 drops after 40 of 100 bytes
  ServeFilePage.read = (k, s) async => MinioByteStream.fromStream(stream: () async* {
        yield List.filled(40, 1);
        throw const SocketException('S3 reset');
      }(), contentLength: 100);
  final (cutStatus, cutGot, cutErr) = await fetch(server.port);
  check('cut stream → client gets no complete response (status $cutStatus, $cutGot B, error $cutErr)',
      cutErr != null && cutGot < 100);

  // S3 ends cleanly but short (40 of 100)
  ServeFilePage.read = (k, s) async =>
      MinioByteStream.fromStream(stream: Stream.value(List.filled(40, 1)), contentLength: 100);
  final (shortStatus, shortGot, shortErr) = await fetch(server.port);
  check('short stream → connection dropped (status $shortStatus, $shortGot B, error $shortErr)',
      shortErr != null && shortGot < 100);

  await server.close(force: true);
  print('\nALL PASSED');
  exit(0);
}
