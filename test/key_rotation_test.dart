// HARD-L.7: light key rotation — IGNIS_KEY_PREVIOUS still decrypts, Crypto.reencrypt moves data to the current key.
// No database: child processes with different keys in the environment.
import 'dart:io';

import 'package:ignis/ignis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

final oldKey = '0123456789abcdef' * 4, newKey = 'fedcba9876543210' * 4;

/// Child: `enc <context|-> <text>`, `dec <context|-> <ciphertext>`, `re <context> <ciphertext>`, `prev`.
Future<String> child(List<String> a, {required String key, String? previous}) async {
  final r = await Process.run(Platform.resolvedExecutable, [Platform.script.toFilePath(), ...a],
      environment: {'IGNIS_KEY': key, if (previous != null) 'IGNIS_KEY_PREVIOUS': previous});
  if (r.exitCode != 0) throw StateError('child ${a.first}: ${r.stderr}');
  return r.stdout as String;
}

Future<void> main(List<String> a) async {
  if (a.isNotEmpty) {
    final context = a.length > 1 && a[1] != '-' ? a[1] : null;
    switch (a.first) {
      case 'enc':
        stdout.write(Crypto.encrypt(a[2], context: context));
      case 'dec':
        stdout.write(Crypto.decrypt(a[2], context: context));
      case 're':
        try {
          stdout.write(Crypto.reencrypt(a[2], context: context!) ?? 'NONE');
        } on FormatException {
          stdout.write('UNREADABLE');
        }
      case 'prev':
        stdout.write(Crypto.previousKeyInvalid ? 'invalid' : 'ok');
    }
    return;
  }
  final v2 = await child(['enc', 'totp|admin', 'SECRET'], key: oldKey);
  final v1 = await child(['enc', '-', 'legacy'], key: oldKey);
  check('without IGNIS_KEY_PREVIOUS an old ciphertext is unreadable',
      await child(['dec', 'totp|admin', v2], key: newKey) == '');
  check('IGNIS_KEY_PREVIOUS reads an old v2 ciphertext',
      await child(['dec', 'totp|admin', v2], key: newKey, previous: oldKey) == 'SECRET');
  check('IGNIS_KEY_PREVIOUS reads an old v1 ciphertext', await child(['dec', '-', v1], key: newKey, previous: oldKey) == 'legacy');
  check('AAD still binds with the previous key',
      await child(['dec', 'totp|other', v2], key: newKey, previous: oldKey) == '');

  final re = await child(['re', 'totp|admin', v2], key: newKey, previous: oldKey);
  check('reencrypt gives a v2 ciphertext', re.startsWith('enc:v2:') && re != v2);
  check('after reencrypt readable without IGNIS_KEY_PREVIOUS', await child(['dec', 'totp|admin', re], key: newKey) == 'SECRET');
  check('reencrypt is idempotent (already under the current key → nothing)',
      await child(['re', 'totp|admin', re], key: newKey, previous: oldKey) == 'NONE');
  check('reencrypt: plaintext → nothing', await child(['re', 'x|y', 'plain'], key: newKey) == 'NONE');
  check('reencrypt: v1 under the current key moves to v2',
      (await child(['re', 'x|y', await child(['enc', '-', 'p'], key: newKey)], key: newKey)).startsWith('enc:v2:'));
  check('reencrypt: unreadable with both keys → reported, not dropped',
      await child(['re', 'totp|admin', v2], key: newKey) == 'UNREADABLE');
  check('a malformed IGNIS_KEY_PREVIOUS is reported', await child(['prev'], key: newKey, previous: 'abc') == 'invalid');
  check('no IGNIS_KEY_PREVIOUS is fine', await child(['prev'], key: newKey) == 'ok');
}
