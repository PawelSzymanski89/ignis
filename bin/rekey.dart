// ============================================================================
//  bin/rekey.dart — re-encrypts stored secrets under the current IGNIS_KEY
// ----------------------------------------------------------------------------
//  Key rotation: put the new key in IGNIS_KEY and the old one in IGNIS_KEY_PREVIOUS on every node,
//  restart them, run this once, then remove IGNIS_KEY_PREVIOUS and restart again.
//
//  Usage:   IGNIS_KEY=<new> IGNIS_KEY_PREVIOUS=<old> dart run bin/rekey.dart
//  Re-encrypts encrypted settings values (AAD "<service>|<key>") and TOTP seeds (AAD "totp|<username>").
//  Idempotent: values already under the current key are left alone, so a second run changes nothing.
//  Exits with 1 when some value is readable with neither key — keep IGNIS_KEY_PREVIOUS until that is explained.
// ============================================================================

import 'dart:io';

import 'package:ignis/engine/audit_log.dart';
import 'package:ignis/engine/crypto.dart';
import 'package:ignis/engine/db.dart';
import 'package:ignis/engine/redis.dart';
import 'package:postgres/postgres.dart' show Sql;

class _Count {
  int reencrypted = 0, current = 0, unreadable = 0, changed = 0;
  @override
  String toString() => '$reencrypted re-encrypted, $current already current, $unreadable unreadable'
      '${changed > 0 ? ', $changed changed meanwhile (run again)' : ''}';
}

/// Re-encrypts [value]; on success writes it with [write] (compare-and-swap on the old value), which returns
/// the number of rows it actually updated — 0 when the value changed since it was read.
Future<void> _one(_Count n, String value, String context, Future<int> Function(String) write, String label) async {
  final String? next;
  try {
    next = Crypto.reencrypt(value, context: context);
  } on FormatException {
    n.unreadable++;
    stderr.writeln('  unreadable: $label');
    return;
  }
  if (next == null) {
    n.current++;
    return;
  }
  if (await write(next) == 0) {
    n.changed++;
    stderr.writeln('  changed meanwhile, not updated: $label');
    return;
  }
  n.reencrypted++;
}

Future<void> main() async {
  if (!Crypto.available || Crypto.previousKeyInvalid) {
    stderr.writeln('IGNIS_KEY (and IGNIS_KEY_PREVIOUS, if set) must be 64 random hex chars');
    exit(2);
  }
  final (settings, totp) = await Db.asSystemSession(_rekey);
  stdout.writeln('settings: $settings');
  stdout.writeln('totp: $totp');
  await Db.asSystem(() => AuditLog.save(
      service: 0, actor: 'rekey', location: 'rekey', action: 'rekey', detail: 'settings: $settings; totp: $totp',
      result: settings.unreadable + totp.unreadable == 0 ? 'ok' : 'error'));
  exit(settings.unreadable + totp.unreadable == 0 ? 0 : 1);
}

Future<(_Count, _Count)> _rekey() async {
  final c = await Db.connect();
  final settings = _Count(), totp = _Count();
  final services = <int>{};
  for (final r in await c.execute("SELECT id, key, value, service FROM settings WHERE value LIKE 'enc:%' ORDER BY id")) {
    final (id, key, value, service) = (r[0] as String, r[1] as String, r[2] as String, r[3] as int);
    await _one(settings, value, '$service|$key', (v) async {
      final r = await c.execute(Sql.named('UPDATE settings SET value=@v WHERE id=@i AND value=@old'),
          parameters: {'v': v, 'i': id, 'old': value});
      services.add(service);
      return r.affectedRows;
    }, 'settings $id');
  }
  for (final r in await c.execute("SELECT username, totp FROM users WHERE totp LIKE 'enc:%' ORDER BY username")) {
    final (username, value) = (r[0] as String, r[1] as String);
    await _one(totp, value, 'totp|$username', (v) async => (await c.execute(
        Sql.named('UPDATE users SET totp=@v WHERE username=@u AND totp=@old'),
        parameters: {'v': v, 'u': username, 'old': value})).affectedRows, 'totp $username');
  }
  // the settings cache holds raw ciphertexts for 60 s — drop it so nodes do not keep the old ones
  try {
    await Redis.delMany([for (final s in services) 'settings:$s']);
  } catch (err) {
    stderr.writeln('  Redis: settings cache not cleared ($err) — it expires on its own within 60 s');
  }
  return (settings, totp);
}
