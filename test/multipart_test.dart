// SEC-B-1: multipart tylko na trasach z maksCiala; limit liczy surowe bajty żądania; limit liczby części i nazwy pola.
// Bez bazy: 413 pada przed pobraniem połączenia, a Upload.odbierz to czysty strumień.
import 'dart:convert';
import 'dart:io';

import 'package:ignis/ignis.dart';
// ignore: unused_import
import 'package:ignis/pages.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

@Page('/test-bez-plikow', technical: true, methods: ['POST'])
class NoFiles extends PageEngine {}

@Page('/test-z-plikami', technical: true, methods: ['POST'], maxBody: 1024, noDb: true)
class WithFiles extends PageEngine {
  @override
  Future<bool> doBeforeProcess() async => respond(200, {'n': files.length});
}

@Page('/test-panel-files', technical: true, methods: ['POST'], maxBody: 1024, noDb: true)
class PanelFiles extends AdminPage {}

const g = 'GRANICA';
List<int> part(String name, String content, {String? file}) => utf8.encode('--$g\r\n'
    'Content-Disposition: form-data; name="$name"${file == null ? '' : '; filename="$file"'}\r\n\r\n$content\r\n');
List<int> end() => utf8.encode('--$g--\r\n');

Future<Object> receive(List<int> body, int limit, {String? boundary = g}) async {
  try {
    return await Upload.receive(Stream.value(body), boundary, byteLimit: limit);
  } catch (e) {
    return e;
  }
}

Future<void> main() async {
  print('Upload.odbierz:');
  final ok = await receive([...part('a', 'x'), ...part('f', 'abc', file: 'p.txt'), ...end()], 1024);
  check('pole i plik w limicie', ok is UploadResult && ok.fields['a'] == 'x' && ok.files.single.data.length == 3);
  final empty = [for (var i = 0; i < 3000; i++) ...part('n$i', ''), ...end()];
  check('same nagłówki części (puste treści) liczą się do limitu → UploadZaDuzy',
      await receive(empty, 16 * 1024) is UploadTooLarge);
  check('ponad ${Upload.maxParts} części → FormatException', await receive(empty, 1 << 30) is FormatException);
  check('nazwa pola dłuższa niż ${Upload.maxFieldName} → FormatException',
      await receive([...part('n' * 300, ''), ...end()], 1 << 20) is FormatException);
  check('brak boundary → FormatException',
      await receive(end(), 10, boundary: null) is FormatException);

  print('Engine:');
  PageRegistry.build();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) => Engine.guarded(req, () => dispatch(req, const [])));
  final client = HttpClient();
  final z = await client.open('POST', '127.0.0.1', server.port, '/test-bez-plikow');
  z.headers
    ..host = 'localhost'
    ..contentType = ContentType('multipart', 'form-data', parameters: {'boundary': g});
  z.add([...part('csrf', 'x'), ...end()]);
  final r = await z.close();
  await r.drain<void>();
  check('multipart na trasie bez maksCiala → 413 (przed CSRF, auth i bazą)', r.statusCode == 413);

  // FIX-3: odmowa PRZED czytaniem body
  final content = [...part('csrf', 'x'), ...part('f', 'abc', file: 'p.txt'), ...end()];
  Future<int> send(String path, {String? cookieNames, bool chunked = false, List<int>? body}) async {
    final z = await client.open('POST', '127.0.0.1', server.port, path);
    z.headers
      ..host = 'localhost'
      ..contentType = ContentType('multipart', 'form-data', parameters: {'boundary': g});
    if (cookieNames != null) z.headers.set('cookie', cookieNames);
    z.headers.chunkedTransferEncoding = chunked;
    if (!chunked) z.contentLength = (body ?? content).length;
    z.add(body ?? content);
    final r = await z.close();
    await r.drain<void>();
    return r.statusCode;
  }

  final csrf = '${Engine.csrfCookie}=x';
  check('poprawny upload z ciasteczkiem CSRF → 200', await send('/test-z-plikami', cookieNames: csrf) == 200);
  check('bez ciasteczka CSRF → 403 przed czytaniem', await send('/test-z-plikami') == 403);
  check('chunked (bez Content-Length) → 413', await send('/test-z-plikami', cookieNames: csrf, chunked: true) == 413);
  check('Content-Length ponad maksCiala → 413',
      await send('/test-z-plikami', cookieNames: csrf, body: [...part('f', 'a' * 2000, file: 'd'), ...end()]) == 413);
  check('strona panelu bez sesji → 403 przed czytaniem', await send('/test-panel-files', cookieNames: csrf) == 403);
  final budget = Engine.multipartBudget;
  Engine.multipartBudget = 10;
  check('ponad budżet równoległych multipartów → 503', await send('/test-z-plikami', cookieNames: csrf) == 503);
  Engine.multipartBudget = budget;
  check('…po zwolnieniu budżetu znowu 200', await send('/test-z-plikami', cookieNames: csrf) == 200);

  final f = await client.open('POST', '127.0.0.1', server.port, '/test-z-plikami');
  f.headers
    ..host = 'localhost'
    ..contentType = ContentType('application', 'x-www-form-urlencoded')
    ..set('cookie', csrf);
  f.write(List.generate(Engine.maxFormFields + 1, (i) => 'p$i=').join('&'));
  final rf = await f.close();
  await rf.drain<void>();
  check('formularz z ponad ${Engine.maxFormFields} polami → 400', rf.statusCode == 400);
  client.close(force: true);
  await server.close(force: true);
  print('\nALL PASSED');
}
