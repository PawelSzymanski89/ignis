// ============================================================================
//  audit_log.dart — writing and reading the trail of panel operations
// ----------------------------------------------------------------------------
//  Writing is called from ONE place (`engine.dart`, after an action runs), so
//  a page cannot be added that quietly stays outside the audit.
//
//  A rule with no exceptions: the audit log must not become a leak
//  channel. Values of fields whose name looks like a secret are stored as
//  "(hidden)". Better to lose a detail than to copy a password into a second table.
// ============================================================================

import 'dart:async';
import 'dart:io';

import 'package:postgres/postgres.dart' show Sql;

import 'db.dart';
import 'config.dart';
import 'redis.dart';

class AuditLogView {
  AuditLogView(this.id, this.service, this.actor, this.location, this.action,
      this.detail, this.target, this.ip, this.occurred_at, this.targetName, this.result);
  final int id, service, target;
  final String actor, location, action, detail, ip, occurred_at, targetName, result;

  String get date => occurred_at.replaceFirst('T', ' ').split('.').first;
}

class AuditLog {
  /// Fields whose values are NEVER stored. Matched by a fragment
  /// of the name, because fields keep coming: `api_token_devel`, `smtp_password`, `dns_app_secret`.
  static const _secrets = [
    'password', 'pass', 'token', 'secret', 'key', 'cert', 'pin',
    // Polish field names are common in apps built on Ignis; a missed secret leaks it for good
    'haslo', 'sekret', 'klucz', 'stare', 'nowe', 'powtorz',
  ];

  /// Password-change fields named without "password" (`old`, `new_pw`, `repeat`).
  static final _passwordLike = RegExp(r'^(old|new|repeat)(_|$)');

  /// Technical fields that add nothing to the audit. `csrf` is here and not
  /// among the secrets: "csrf=(hidden)" in every row is pure noise.
  static const _skipped = {'triggerAction', '__ip', 'csrf', 'flash', 'flash_type', 'flash_sig'};

  static const _detailLimit = 500;

  /// Whether the value of field [name] is a secret — shared by the audit log and the form echo
  /// ([PageEngine.prepareFormErrors]). Settings fields `p_<key>` by [Field.secret], not by name.
  static bool secret(String name) {
    final n = name.toLowerCase();
    if (name.startsWith('p_') && secretKeys.contains(name.substring(2))) return true;
    // `code` (TOTP) exactly — a fragment would also hide `code_postal`
    return n == 'code' || n == 'kod' || _passwordLike.hasMatch(n) || _secrets.any(n.contains);
  }

  /// Form parameters in a form suitable for the audit log.
  static String describe(Map<String, String> params) {
    final parts = <String>[];
    for (final e in params.entries) {
      if (_skipped.contains(e.key) || e.key.startsWith('__')) continue;
      if (secret(e.key)) {
        parts.add('${e.key}=(hidden)');
        continue;
      }
      final v = e.value.trim();
      if (v.isEmpty) continue;
      parts.add('${e.key}=${v.length > 60 ? '${v.substring(0, 60)}…' : v}');
    }
    final s = parts.join(' · ');
    return s.length > _detailLimit ? '${s.substring(0, _detailLimit)}…' : s;
  }

  /// Writes an entry. Never throws: the audit must not break the operation it
  /// describes. The error goes to stderr, because quietly losing the trail is worse than noise.
  static Future<void> save({
    required int service,
    required String actor,
    required String location,
    required String action,
    String detail = '',
    int target = 0,
    String ip = '',
    String result = 'ok',
  }) async {
    // the login from the sign-in form is written by the client — without a length limit it would carry garbage
    if (actor.length > 64) actor = '${actor.substring(0, 64)}…';
    try {
      // savepoint in the request transaction: a failed entry does not roll back the change it describes
      await (await Db.connect()).runTx((tx) => tx.execute(
        Sql.named('''INSERT INTO audit_log (service, actor, location, action, detail, target, ip, occurred_at, result)
                     VALUES (@u, @k, @g, @c, @s, @t, @i, @d, @w)'''),
        parameters: {
          'u': service, 'k': actor, 'g': location, 'c': action, 's': detail,
          't': target, 'i': ip, 'd': DateTime.now().toIso8601String(), 'w': result,
        }));
    } catch (e) {
      stderr.writeln('Ignis audit log: entry not saved ($location/$action): $e');
    }
  }

  /// Author label of a platform entry seen in a service — the operator login and IP
  /// stay on the platform side. A login from `[a-zA-Z0-9._-]` will not collide with "support".
  static const handler = 'support';

  /// `actor`/`ip` as the service sees them: a row of another service (the platform, `target = @s`) without login and IP.
  static String _authorExpr(bool all, [String a = '']) =>
      all ? '${a}actor' : "CASE WHEN ${a}service = @u THEN ${a}actor ELSE '$handler' END";
  static String _ip(bool all, [String a = '']) =>
      all ? '${a}ip' : "CASE WHEN ${a}service = @u THEN ${a}ip ELSE '' END";

  /// Author filter without a CASE expression on the left — the `actor` index works. In a service "support" means
  /// platform entries about it, and any other login — only that service's entries (an operator login finds nothing).
  static String _authorFilter(bool all, String actor, [String a = '']) => all
      ? '${a}actor = @kt'
      : actor == handler
          ? '${a}service <> @u'
          : '${a}actor = @kt AND ${a}service = @u';

  /// Entries to show, newest first. The platform (`service = 0`) sees everything — including what
  /// it did at a customer; a service sees only its own. Paging by id (keyset), no OFFSET:
  /// [before] = older than this entry, [after] = newer (the nearest [limit]).
  static Future<List<AuditLogView>> list(
    int service, {
    bool all = false,
    String actor = '',
    String search = '',
    int limit = 100,
    int? before,
    int? after,
  }) async {
    final conditions = <String>[];
    final pairs = <String, Object?>{'l': limit};
    if (!all) {
      // a customer sees its service's entries AND what the platform did at it
      conditions.add('(d.service = @u OR d.target = @u)');
      pairs['u'] = service;
    }
    if (actor.isNotEmpty) {
      conditions.add(_authorFilter(all, actor, 'd.'));
      if (all || actor != handler) pairs['kt'] = actor;
    }
    if (before != null) {
      conditions.add('d.id < @p');
      pairs['p'] = before;
    } else if (after != null) {
      conditions.add('d.id > @p');
      pairs['p'] = after;
    }
    if (search.isNotEmpty) {
      conditions.add("d.occurred_at >= @since AND (d.location ILIKE @q OR d.action ILIKE @q OR d.detail ILIKE @q OR ${_authorExpr(all, 'd.')} ILIKE @q)");
      pairs['q'] = '%$search%';
      pairs['since'] = _searchFrom();
    }
    final r = await (await Db.connect()).execute(
      Sql.named('''SELECT d.id, d.service, ${_authorExpr(all, 'd.')}, d.location, d.action, d.detail,
                          d.target, ${_ip(all, 'd.')}, d.occurred_at, coalesce(u.name, ''), d.result
                   FROM audit_log d
                   LEFT JOIN services u ON u.id = nullif(d.target, 0)
                   ${conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}'}
                   ORDER BY d.id ${before == null && after != null ? 'ASC' : 'DESC'} LIMIT @l'''),
      parameters: pairs);
    final w = [
      for (final x in r)
        AuditLogView(x[0] as int, x[1] as int, x[2] as String, x[3] as String,
            x[4] as String, x[5] as String, x[6] as int, x[7] as String,
            x[8] as String, x[9] as String, x[10] as String)
    ];
    return before == null && after != null ? w.reversed.toList() : w;
  }

  /// A phrase (ILIKE with a leading %) searches only the last [searchDays] days —
  /// without a window every view with a phrase scanned all 400 days of entries.
  static const searchDays = 30;
  static String _searchFrom() => DateTime.now().subtract(const Duration(days: searchDays)).toIso8601String();

  /// Exact entry count — `count(*)` after the filter; the panel does not use it (paging by id).
  static Future<int> count(int service, {bool all = false, String actor = '', String search = ''}) async {
    final conditions = <String>[];
    final pairs = <String, Object?>{};
    if (!all) {
      conditions.add('(service = @u OR target = @u)');
      pairs['u'] = service;
    }
    if (actor.isNotEmpty) {
      conditions.add(_authorFilter(all, actor));
      if (all || actor != handler) pairs['kt'] = actor;
    }
    if (search.isNotEmpty) {
      conditions.add('occurred_at >= @since AND (location ILIKE @q OR action ILIKE @q OR detail ILIKE @q OR ${_authorExpr(all)} ILIKE @q)');
      pairs['q'] = '%$search%';
      pairs['since'] = _searchFrom();
    }
    final r = await (await Db.connect()).execute(
      Sql.named('''SELECT count(*)::int FROM audit_log
                   ${conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}'}'''),
      parameters: pairs);
    return r.first[0] as int;
  }

  /// How many days entries are kept — a year with a margin.
  static const retentionDays = 400;

  static Timer? _timer;

  /// Cleanup once a day, one node at a time. Without it the table grows
  /// forever — an entry is created on EVERY panel action.
  static void start({Duration what = const Duration(hours: 24)}) {
    _timer?.cancel();
    _timer = Timer.periodic(what, (_) => purgeSafely());
    purgeSafely();
  }

  static Future<void> purgeSafely() async {
    try {
      if (!await Redis.setNxEx(
          'lock:audit_log', Platform.environment['IGNIS_NODE'] ?? 'node', 3600)) {
        return;
      }
      final count = await Db.asSystem(purge);
      if (count > 0) stdout.writeln('Ignis audit log: deleted $count old entries');
    } catch (e) {
      stderr.writeln('Ignis audit log: cleanup — $e');
    }
  }

  /// Deletes entries older than [retentionDays]. Returns the number deleted.
  static Future<int> purge({int? days}) async {
    final boundary = DateTime.now()
        .subtract(Duration(days: days ?? retentionDays))
        .toIso8601String();
    final r = await (await Db.connect()).execute(
      Sql.named('DELETE FROM audit_log WHERE occurred_at < @g'),
      parameters: {'g': boundary});
    return r.affectedRows;
  }

  /// Author of a failed sign-in to a non-existent account (the login from the form does not go to the audit log).
  static const unknown = '(unknown)';

  /// Most entries in the author filter.
  static const maxAuthors = 200;

  /// For the page filter: back-office accounts (service — only its own), [unknown] and, in a service, [handler].
  /// From `users`, not DISTINCT over the audit log — entries with a foreign `actor` do not inflate the list. Kept
  /// [_authorsTtl] in node memory.
  static Future<List<String>> authors(int service, {bool all = false}) async {
    final key = all ? -1 : service;
    final c = _authors[key];
    if (c != null && DateTime.now().isBefore(c.$1)) return c.$2;
    final w = await _authorsFromDb(service, all: all);
    _authors[key] = (DateTime.now().add(_authorsTtl), w);
    return w;
  }

  static const _authorsTtl = Duration(minutes: 5);
  static final _authors = <int, (DateTime, List<String>)>{};

  static Future<List<String>> _authorsFromDb(int service, {required bool all}) async {
    final r = await (await Db.connect()).execute(
      Sql.named('''SELECT username FROM users WHERE realm = 'staff' ${all ? '' : 'AND service = @u'}
                   ORDER BY username LIMIT $maxAuthors'''),
      parameters: all ? {} : {'u': service});
    return [for (final x in r) x[0] as String, unknown, if (!all) handler];
  }
}
