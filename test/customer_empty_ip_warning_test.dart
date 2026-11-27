// IGNIS-054.7: loginWithPassword / resetToken without `ip:` put every client into one rate-limit bucket — one stderr
// warning per process says so (the API stays the same). No database: an invalid e-mail returns before Redis / DB.
// Run: dart run test/customer_empty_ip_warning_test.dart
import 'dart:io';

import 'package:ignis/engine/customer_accounts.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  final lines = <String>[];
  await IOOverrides.runZoned(() async {
    await CustomerAccounts.loginWithPassword(1, 'not-an-email', 'x', ip: '203.0.113.7');
    await CustomerAccounts.resetToken(1, 'not-an-email', ip: '203.0.113.7');
  }, stderr: () => _Collector(lines));
  check('with ip: no warning', lines.where((l) => l.contains('ip')).isEmpty);

  await IOOverrides.runZoned(() async {
    await CustomerAccounts.loginWithPassword(1, 'not-an-email', 'x');
    await CustomerAccounts.loginWithPassword(1, 'not-an-email', 'x');
    await CustomerAccounts.resetToken(1, 'not-an-email');
  }, stderr: () => _Collector(lines));
  final w = lines.where((l) => l.contains('without ip')).toList();
  print('  ${w.join('\n  ')}');
  check('without ip: exactly one warning for the process', w.length == 1);
  print('\nALL PASSED');
}

class _Collector implements Stdout {
  _Collector(this.lines);
  final List<String> lines;
  @override
  void writeln([Object? o = '']) => lines.add('$o');
  @override
  dynamic noSuchMethod(Invocation i) => null;
}
