// ============================================================================
//  bin/account.dart — emergency account operations from the server console
// ----------------------------------------------------------------------------
//  The way out when the door is locked: the only platform administrator lost
//  the phone with the second factor, or nobody remembers the password. The
//  panel cannot fix that — you have to be signed in to help someone.
//
//  The tool needs access to the server and to `.env` with `IGNIS_KEY`, i.e. the
//  same as database access. It does not lower the bar: whoever gets here could
//  run the UPDATE by hand anyway — only without an audit log entry.
//
//  Usage (on a node, after `set -a && . ./.env`):
//    dart run bin/account.dart list
//    dart run bin/account.dart disable-2fa <login>
//    dart run bin/account.dart password <login>   (new password from stdin, no echo)
// ============================================================================

import 'dart:io';

import 'package:ignis/engine/db.dart';
import 'package:ignis/engine/audit_log.dart';
import 'package:ignis/engine/permissions.dart';
import 'package:postgres/postgres.dart' show Sql;

Future<void> main(List<String> a) => Db.asSystemSession(() => _main(a));

Future<void> _main(List<String> a) async {
  if (a.isEmpty) {
    stdout.writeln('Usage: list | disable-2fa <login> | password <login>');
    exit(2);
  }
  final c = await Db.connect();

  switch (a.first) {
    case 'list':
      final r = await c.execute('''SELECT username, realm, service,
                                          coalesce(must_change_password, false),
                                          coalesce(totp, '') <> ''
                                   FROM users WHERE realm = 'staff' ORDER BY service, username''');
      stdout.writeln('login | service | must change password | has second factor');
      for (final x in r) {
        stdout.writeln('${x[0]} | ${x[2] == 0 ? 'platform' : x[2]} | ${x[3]} | ${x[4]}');
      }

    case 'disable-2fa':
      if (a.length < 2) exit(2);
      final login = a[1];
      if (!await _exists(c, login)) {
        stdout.writeln('No account "$login".');
        exit(1);
      }
      await Permissions.setTotp(login, '');
      await _trace(login, 'second factor disabled from server console');
      stdout.writeln('Account "$login" now signs in with the password alone. '
          'Enable the second factor again in "My account" as soon as you are in.');

    case 'password':
      if (a.length != 2) exit(2);
      final login = a[1], password = _passwordFromStdin('New password for "$login": ');
      final wrong = Db.passwordError(password);
      if (wrong != null) {
        stdout.writeln(wrong);
        exit(1);
      }
      if (!await _exists(c, login)) {
        stdout.writeln('No account "$login".');
        exit(1);
      }
      // force a change: the console operator knows this password too
      await Permissions.changePassword(login, password, 0, all: true);
      await _trace(login, 'password reset from server console');
      stdout.writeln('Password set. The panel will ask for a change on first sign-in, '
          'and all old sessions have been closed.');

    default:
      stdout.writeln('Unknown command "${a.first}".');
      exit(2);
  }
  exit(0);
}

Future<bool> _exists(dynamic c, String login) async =>
    (await c.execute(Sql.named("SELECT 1 FROM users WHERE username=@u AND realm='staff'"),
            parameters: {'u': login}))
        .isNotEmpty;

/// An emergency operation leaves a trace too — otherwise it would be a silent back door.
Future<void> _trace(String login, String what) async {
  final k = await Db.account(login);
  await AuditLog.save(
    service: 0,
    actor: 'console:${Platform.environment['SUDO_USER'] ?? Platform.environment['USER'] ?? 'root'}',
    location: 'bin/account.dart',
    action: what,
    detail: 'account=$login',
    target: k?.$2 ?? 0,
    ip: Platform.environment['SSH_CLIENT']?.split(' ').first ?? '',
  );
}

/// Password from standard input, not argv (argv shows up in `ps` and shell history).
/// No echo on a terminal; in a pipe — the first line (`printf '%s\n' "$H" | dart run …`).
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
