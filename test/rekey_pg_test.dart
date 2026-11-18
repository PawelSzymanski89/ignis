// HARD-L.7: bin/rekey.dart moves settings secrets and TOTP seeds to the new IGNIS_KEY; afterwards they
// are readable without IGNIS_KEY_PREVIOUS and TOTP still works. Run: tool/pg_test.sh test/rekey_pg_test.dart
import 'dart:io';

import 'package:bcrypt/bcrypt.dart';
import 'package:ignis/ignis.dart';
// ignore: unused_import
import 'package:ignis/entities.dart';
import 'package:postgres/postgres.dart' show Sql;

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

const login = 'rekeytest', field = 'test.password', service = 7;
final newKey = 'fedcba9876543210' * 4;

void _sections() => Ignis.settingsSections = const [
      Section('test', 'Test', '', '', [Field(field, 'Password', type: FieldType.password)]),
    ];

/// Child process with [key] (and optionally [previous]) instead of the test key.
Future<ProcessResult> run(List<String> args, {required String key, String? previous}) => Process.run(
    Platform.resolvedExecutable, args,
    environment: {'IGNIS_KEY': key, if (previous != null) 'IGNIS_KEY_PREVIOUS': previous});

Future<void> main(List<String> a) async {
  if (Platform.environment['IGNIS_DB_HOST'] == null) {
    print('  skipped — no IGNIS_DB_HOST (tool/pg_test.sh)');
    return;
  }
  EntityRegistry.build();
  _sections();
  if (a.isNotEmpty) {
    // child: what a node with only the current key reads
    final (totp, settings) = await Db.asSystem(() async => (await Permissions.totpSecret(login), await Permissions.settings(service)));
    stdout.write('${totp.isNotEmpty && Totp.matches(totp, Totp.code(totp)!) ? totp : '-'}|${settings[field]}');
    exit(0);
  }
  await Schema.sync();
  final oldKey = Platform.environment['IGNIS_KEY']!;
  final secret = Totp.newSecret();
  await Db.asSystem(() async {
    final c = await Db.connect();
    // ciphertexts left by other tests in the shared test database (one deliberately unreadable) — exact counts below
    await c.execute("DELETE FROM settings WHERE value LIKE 'enc:%'");
    await c.execute("UPDATE users SET totp='' WHERE totp LIKE 'enc:%'");
    await c.execute(Sql.named('DELETE FROM users WHERE username=@u'), parameters: {'u': login});
    await c.execute(Sql.named("INSERT INTO users (username, pass_hash, realm, service) VALUES (@u, @h, 'staff', 0)"),
        parameters: {'u': login, 'h': BCrypt.hashpw('Password-123-x', BCrypt.gensalt(logRounds: 4))});
    await Permissions.setTotp(login, secret);
    await Permissions.saveSetting(service, field, 'smtp-secret');
  });
  await Redis.del('settings:$service');
  final me = Platform.script.toFilePath();

  var r = await run([me, 'read'], key: newKey);
  check('before rekey the new key alone reads nothing', r.stdout == '-|');
  r = await run([me, 'read'], key: newKey, previous: oldKey);
  check('IGNIS_KEY_PREVIOUS reads the old TOTP seed and setting', r.stdout == '$secret|smtp-secret');

  r = await run(['bin/rekey.dart'], key: newKey, previous: oldKey);
  check('rekey succeeds', r.exitCode == 0);
  check('rekey reports the records', '${r.stdout}'.contains('settings: 1 re-encrypted') && '${r.stdout}'.contains('totp: 1 re-encrypted'));
  r = await run([me, 'read'], key: newKey);
  check('after rekey readable without IGNIS_KEY_PREVIOUS, TOTP works', r.stdout == '$secret|smtp-secret');

  r = await run(['bin/rekey.dart'], key: newKey, previous: oldKey);
  check('second run is idempotent', r.exitCode == 0 && '${r.stdout}'.contains('settings: 0 re-encrypted, 1 already current') &&
      '${r.stdout}'.contains('totp: 0 re-encrypted, 1 already current'));
  r = await run(['bin/rekey.dart'], key: 'abcdef0123456789' * 4);
  check('a key that reads nothing → unreadable reported, exit 1', r.exitCode == 1 && '${r.stdout}'.contains('1 unreadable'));

  await Db.asSystem(() async => (await Db.connect()).execute(Sql.named('DELETE FROM users WHERE username=@u'), parameters: {'u': login}));
  await Db.close();
  print('\nALL PASSED');
  exit(0);
}
