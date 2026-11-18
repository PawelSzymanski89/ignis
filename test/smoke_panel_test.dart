// FIX-47: smoke_panel nie wyśle hasła ani ciasteczek po http:// poza lokalną maszynę.
import 'dart:io';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  for (final address in ['http://admin.example.com', 'ftp://example.com', 'http://127.0.0.1.evil.example']) {
    final p = await Process.start(Platform.resolvedExecutable, ['run', 'bin/smoke_panel.dart', address, 'x']);
    await p.stdin.close();
    final err = await p.stderr.transform(const SystemEncoding().decoder).join();
    check('$address → odmowa przed pytaniem o hasło', await p.exitCode == 2 && err.contains('https://'));
  }
}
