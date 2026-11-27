// IGNIS-053.2: aliases of one file (/assets//x/a.css, /assets/%2Fx/a.css, /assets/x%5Ca.css, /assets/x/a.css/) → 400.
// Each alias used to add its own entry to assetVersions / the gzip cache — unbounded memory growth. Without a database.
import 'dart:io';

import '../lib/engine/ignis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  final t = Directory.systemTemp.createTempSync('alias');
  Directory('${t.path}/x').createSync();
  File('${t.path}/x/a.css').writeAsStringSync('body{color:red}');
  final m = Mount('/sdk/', t.path);
  final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  srv.listen((req) => dispatch(req, [t.path]));
  final saved = Ignis.mounts;
  Ignis.mounts = [m];
  // raw request target: HttpClient/Uri would normalize some of the aliases before they reach the server
  // (a raw `\` and `.`/`%2E` segments are normalized by the server's Uri parser — same key, not aliases)
  Future<int> status(String path) async {
    final sock = await Socket.connect('127.0.0.1', srv.port);
    sock.write('GET $path HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n');
    final bytes = (await sock.toList()).expand((b) => b).toList();
    sock.destroy();
    return int.parse(String.fromCharCodes(bytes.take(12)).split(' ')[1]);
  }

  try {
    check('/assets/x/a.css → 200', await status('/assets/x/a.css') == 200);
    check('/sdk/x/a.css → 200', await status('/sdk/x/a.css') == 200);
    final before = assetVersions.length;
    for (final alias in ['//x/a.css', '/x//a.css', '%2Fx/a.css', 'x%2F%2Fa.css', '%5Cx/a.css', 'x%5Ca.css',
        'x///a.css', 'x/a.css/']) {
      check('/assets/$alias → 400', await status('/assets/$alias') == 400);
      check('/sdk/$alias → 400', await status('/sdk/$alias') == 400);
    }
    check('assetVersions did not grow', assetVersions.length == before);
    check('normal path still 200', await status('/assets/x/a.css') == 200 && await status('/sdk/x/a.css') == 200);
  } finally {
    Ignis.mounts = saved;
    await srv.close();
    t.deleteSync(recursive: true);
  }
}
