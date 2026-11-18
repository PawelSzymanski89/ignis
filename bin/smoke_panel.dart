// ============================================================================
//  bin/smoke_panel.dart — a walk through the WHOLE panel on a signed-in account
// ----------------------------------------------------------------------------
//  Unit tests do not touch SQL and templates all together, so a bug
//  in a query can lie unnoticed for weeks: an `ORDER BY` with an alias broke a page
//  for a whole month, because nobody opened it while signed in.
//  This script opens every panel route and says which one returns 500.
//
//  Usage: dart run bin/smoke_panel.dart https://admin.example.com <login>   (password from stdin, no echo)
//  Exits with code 1 if any page answered with a server error.
// ============================================================================

import 'dart:convert';
import 'dart:io';

import 'package:ignis/engine/registry.dart';
// ignore: unused_import
import 'package:ignis/pages.dart';

final _client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
final _cookieJar = <String, String>{};

Future<(int, int, String)> _task(String url, {Map<String, String>? form}) async {
  final target = Uri.parse(url);
  // `*.localhost` is resolved to the loopback by browsers, not always by the OS resolver
  final viaLoopback = target.host.endsWith('.localhost');
  final req = await _client.openUrl(
      form == null ? 'GET' : 'POST', viaLoopback ? target.replace(host: '127.0.0.1') : target);
  if (viaLoopback) req.headers.host = target.host;
  req.followRedirects = false;
  if (_cookieJar.isNotEmpty) {
    req.headers.set('cookie', _cookieJar.entries.map((e) => '${e.key}=${e.value}').join('; '));
  }
  if (form != null) {
    final body = form.entries
        .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    req.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
    req.headers.contentLength = utf8.encode(body).length;
    req.write(body);
  }
  final res = await req.close();
  for (final c in res.cookies) {
    _cookieJar[c.name] = c.value;
  }
  final content = await res.transform(utf8.decoder).join();
  return (res.statusCode, content.length, res.headers.value('location') ?? '');
}

Future<void> main(List<String> a) async {
  if (a.length != 2) {
    stdout.writeln('Usage: dart run bin/smoke_panel.dart <panel-url> <login>  (password from stdin)');
    exit(2);
  }
  final db = a[0].replaceAll(RegExp(r'/+$'), '');
  // the password and session cookies must not travel in plain text — http only to the local machine
  final u = Uri.tryParse(db);
  if (u == null || !(u.scheme == 'https' || (u.scheme == 'http' && _local(u.host)))) {
    stderr.writeln('The panel address must be https:// (http:// only for *.localhost/127.0.0.1).');
    exit(2);
  }
  PageRegistry.build();

  stdout.writeln('=== PANEL SMOKE: $db ===\n');
  await _task('$db/admin/login'); // for the CSRF cookie
  final csrf = _cookieJar['__Host-ignis_csrf'] ?? '';
  final (code, _, whereTo) = await _task('$db/admin/login',
      form: {'csrf': csrf, 'username': a[1], 'password': _passwordFromStdin('Password for "${a[1]}": ')});
  if (code != 302) {
    stdout.writeln('!!! sign-in failed (status $code) — check the login and password');
    exit(1);
  }
  stdout.writeln('signed in → $whereTo\n');

  // panel routes from the registry: the same source the menu is built from,
  // so a new page is covered by the run without adding it here
  final routes = [
    for (final r in PageRegistry.routes)
      if (r.startsWith('/admin') && !r.contains('logout') && !r.contains('login')) r
  ]..sort();

  var errors = 0, skipped = 0;
  for (final t in routes) {
    final (k, dl, target) = await _task('$db$t');
    final description = switch (k) {
      200 => 'OK   ${dl}B',
      302 => 'przekierowanie → $target',
      404 => 'none (correct for platform pages in a customer panel)',
      403 => 'no permission',
      _ => 'ERROR',
    };
    if (k >= 500) {
      errors++;
    } else if (k != 200) {
      skipped++;
    }
    stdout.writeln('${k >= 500 ? '!!!' : '   '} $t → $k $description');
  }

  stdout.writeln('\n${routes.length} routes · ${routes.length - errors - skipped} opened · '
      '$skipped unavailable to this account · $errors with a server error');
  stdout.writeln(errors == 0 ? '=== ALL OK ===' : '=== ERRORS: $errors ===');
  _client.close();
  exit(errors == 0 ? 0 : 1);
}

/// Password from standard input, not from argv (argv is visible in `ps` and in shell history).
/// On a terminal without echo; in a pipe — the first line (`printf '%s\n' "$H" | dart run …`).
String _passwordFromStdin(String question) {
  stdout.write(question);
  final tty = stdin.hasTerminal;
  if (tty) stdin.echoMode = false;
  try {
    return stdin.readLineSync() ?? '';
  } finally {
    if (tty) {
      stdin.echoMode = true;
      stdout.writeln();
    }
  }
}

/// Loopback hosts — `*.localhost` resolves to the loopback (RFC 6761), as in the README quick start.
bool _local(String host) => host == 'localhost' || host.endsWith('.localhost') || host == '127.0.0.1';
