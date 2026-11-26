// ============================================================================
//  bin/purge.dart — deletes a service together with ALL its data
// ----------------------------------------------------------------------------
//  The panel does not and will not have a "delete service" button: deleting someone's
//  company with one click is not a feature but an accident waiting for a
//  mistake. Here, on the server console, after a database backup — go ahead.
//
//  Usage:   dart run bin/purge.dart list
//           dart run bin/purge.dart delete <slug> [<slug> ...]
//  Before deleting it prints how much of what will disappear and requires a confirmation word.
//  Deletes: storage objects t<id>/, the service's rows (one transaction), account sessions,
//  permission and settings caches in Redis; leaves an entry in the platform audit log.
// ============================================================================

import 'dart:io';

import 'package:ignis/engine/db.dart';
import 'package:ignis/engine/audit_log.dart';
import 'package:ignis/engine/storage.dart';
import 'package:ignis/engine/permissions.dart';
import 'package:ignis/engine/redis.dart';
import 'package:ignis/engine/session.dart';
import 'package:ignis/engine/tenant.dart';
import 'package:postgres/postgres.dart' show Sql;

/// Tables with a `service` column, in an order safe for foreign keys.
/// The list is computed from the database, not from memory — a new table must not be left orphaned.
Future<List<String>> _tablesWithService() async {
  final r = await (await Db.connect()).execute('''
    SELECT table_name FROM information_schema.columns
    WHERE table_schema='public' AND column_name='service' ORDER BY table_name''');
  return [for (final x in r) x[0] as String];
}

Future<void> main(List<String> a) => Db.asSystemSession(() => _main(a));

Future<void> _main(List<String> a) async {
  if (a.isEmpty) {
    stdout.writeln('Usage: list | delete <slug> [<slug> ...]');
    exit(2);
  }
  final c = await Db.connect();

  if (a.first == 'list') {
    final r = await c.execute('''
      SELECT u.id, u.slug, u.name, u.active,
             (SELECT count(*) FROM users s WHERE s.service=u.id)
      FROM services u ORDER BY u.id''');
    stdout.writeln('id | slug | name | active | accounts');
    for (final x in r) {
      stdout.writeln(x.join(' | '));
    }
    exit(0);
  }

  final slugs = a.skip(1).toList();
  if (slugs.isEmpty) exit(2);

  final toDelete = <int, String>{};
  for (final s in slugs) {
    final r = await c.execute(Sql.named('SELECT id FROM services WHERE slug=@s'),
        parameters: {'s': s});
    if (r.isEmpty) {
      stdout.writeln('No service "$s" — stopping, so a typo does not delete another one.');
      exit(1);
    }
    toDelete[r.first[0] as int] = s;
  }

  final tables = await _tablesWithService();
  stdout.writeln('To delete: ${toDelete.entries.map((e) => '${e.value} (#${e.key})').join(', ')}');
  for (final e in toDelete.entries) {
    final count = <String>[];
    for (final t in tables) {
      final r = await c.execute(
        Sql.named('SELECT count(*)::int FROM "$t" WHERE service=@u'), parameters: {'u': e.key});
      final n = r.first[0] as int;
      if (n > 0) count.add('$t: $n');
    }
    stdout.writeln('  ${e.value} → ${count.isEmpty ? 'no data' : count.join(', ')}');
  }

  stdout.write('\nType DELETE to confirm: ');
  if ((stdin.readLineSync() ?? '').trim() != 'DELETE') {
    stdout.writeln('Nothing deleted.');
    exit(1);
  }

  final operator = 'console:${Platform.environment['SUDO_USER'] ?? Platform.environment['USER'] ?? 'root'}';
  for (final e in toDelete.entries) {
    final id = e.key;
    final logins = [
      for (final r in await c.execute(Sql.named('SELECT username FROM users WHERE service=@u'), parameters: {'u': id}))
        r[0] as String
    ];
    // Storage first: after the rows are deleted there would be no way to repeat the cleanup, and objects under t<id>/ would stay
    // downloadable. Stopping here leaves the database untouched — just run it again.
    var objectCount = 0;
    if (Storage.enabled) {
      final keys = [
        await for (final l in Storage.client.listObjectsV2(Storage.bucket, prefix: 't$id/', recursive: true))
          for (final o in l.objects) o.key!
      ];
      await Storage.client.removeObjects(Storage.bucket, keys);
      objectCount = keys.length;
    }
    await c.runTx((tx) async {
      // account packages and grants have no `service` column, so a scan by schema would not catch them
      await tx.execute(
          Sql.named('DELETE FROM user_packages WHERE username IN (SELECT username FROM users WHERE service=@u)'),
          parameters: {'u': id});
      await tx.execute(
          Sql.named('DELETE FROM user_permissions WHERE username IN (SELECT username FROM users WHERE service=@u)'),
          parameters: {'u': id});
      await tx.execute(
          Sql.named('DELETE FROM package_permissions WHERE package_id IN (SELECT id FROM packages WHERE service=@u)'),
          parameters: {'u': id});
      for (final t in tables) {
        await tx.execute(Sql.named('DELETE FROM "$t" WHERE service=@u'), parameters: {'u': id});
      }
      // platform entries about this service (target) stay — that is the operators' trail, not customer data
      await tx.execute(Sql.named('DELETE FROM services WHERE id=@u'), parameters: {'u': id});
    });
    // After the database: the accounts no longer exist, so nobody can open a new session between the steps.
    try {
      for (final l in logins) {
        await Sessions.destroyAll(l);
      }
      await Permissions.invalidateMany(logins); // perm:{l} + generation bump (IGNIS-052.7)
      final clients = [for (final l in logins) if (l.startsWith('c:$id:')) l.substring('c:$id:'.length)];
      final customerSessions = [for (final k in clients) ...await Redis.smembers('csessuser:$id|$k')];
      await Redis.delMany([
        for (final t in customerSessions) 'csess:$t',
        for (final k in clients) 'csessuser:$id|$k',
        'settings:$id',
      ]);
    } catch (err) {
      stderr.writeln('  Redis: sessions/cache of #$id not cleared ($err) — they expire on their own after the TTL');
    }
    await AuditLog.save(
      service: 0,
      actor: operator,
      location: 'bin/purge.dart',
      action: 'delete_service',
      detail: 'slug=${e.value} accounts=${logins.length} objects=$objectCount',
      target: id,
      ip: Platform.environment['SSH_CLIENT']?.split(' ').first ?? '',
    );
    stdout.writeln('  deleted #$id (accounts: ${logins.length}, storage objects: $objectCount)');
  }
  await Tenants.refresh();
  stdout.writeln('Gotowe.');
  exit(0);
}
