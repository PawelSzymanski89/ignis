// ============================================================================
//  session.dart — sessions in a SHARED Redis (works across many nodes)
// ----------------------------------------------------------------------------
//  token→user lives in Redis, not in node RAM. So the load balancer does
//  round-robin (the node changes) and every node reads the session from Redis.
//
//  Next to the token we keep a `sessuser:<login>` set with this account's tokens — so
//  a password change or account removal ends ALL its sessions at once,
//  not after 8 hours.
// ============================================================================

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;
import 'package:postgres/postgres.dart' show Sql;

import 'db.dart';
import 'redis.dart';

/// Session data of a signed-in user.
class Session {
  Session(this.username, [this.epoch = 0]);
  final String username;

  /// `users.session_epoch` at sign-in time — the panel compares it with the database.
  final int epoch;
}

class Sessions {
  /// Name of the session token cookie.
  // __Host-: only from our host, Path=/, Secure, no Domain — a neighbouring service (a.sys vs b.sys)
  // cannot plant a cookie for the whole domain (fixation / login CSRF; SEC-A-13).
  static const cookieName = '__Host-ignis_session';

  /// Session lifetime (8h).
  static const _ttl = 60 * 60 * 8;

  /// How long to type in the code from the app.
  static const _secondFactorTtl = 300;

  /// Session TTL in seconds — also used by @SessionSynced.
  static int get ttlSeconds => _ttl;

  static final _rng = Random.secure();

  /// Creates a session in Redis, returns the token to send as a cookie. A sign-in passes the [epoch] read together
  /// with the password hash ([Db.checkLoginWithEpoch]); without it the current one is read.
  static Future<String> create(String username, {int? epoch}) async {
    final token = _token();
    await Redis.setEx('sess:${hashToken(token)}', jsonEncode([username, epoch ?? await _epoch(username)]), _ttl);
    try {
      await Redis.sadd('sessuser:$username', hashToken(token));
      await Redis.expire('sessuser:$username', _ttl);
    } catch (_) {/* the set is auxiliary — the session works anyway */}
    return token;
  }

  static Future<int> _epoch(String username) async {
    final e = await (await Db.connect())
        .execute(Sql.named('SELECT session_epoch FROM users WHERE username=@u'), parameters: {'u': username});
    return e.isEmpty ? 0 : e.first[0] as int;
  }

  static final _tokenFormat = RegExp(r'^[0-9a-f]{48}$');

  /// A token in the [_token] format — any other (e.g. `X:synced:Class.field`) would hit someone else's
  /// Redis key under the `sess:`/`2fa:` prefix (SEC-A-6). Checked before every read.
  static bool validToken(String? t) => t != null && _tokenFormat.hasMatch(t);

  /// The token, if it points to a live session — for @SessionSynced fields, which must neither
  /// be created nor read for a made-up cookie.
  static Future<String?> alive(String? token) async => await get(token) == null ? null : token;

  /// The Redis key holds a digest of the token, not the token — a Redis dump gives no live sessions (SEC-A-13).
  static String hashToken(String token) => sha256.convert(utf8.encode(token)).toString();

  static String _token() =>
      List.generate(24, (_) => _rng.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Sign-in paused between the password and the code from the app. The account is already
  /// authenticated by password, but there is NO session yet — if there were, the second
  /// factor would protect nothing.
  /// It keeps the [epoch] of the password step: the session after the code carries it, so "sign out everywhere"
  /// in between ends it too.
  static Future<String> halfSession(String username, {int? epoch}) async {
    final token = _token();
    await Redis.setEx('2fa:${hashToken(token)}', jsonEncode([username, epoch ?? await _epoch(username)]), _secondFactorTtl);
    return token;
  }

  /// Who is waiting for the code (without using up the token — the code may be mistyped).
  static Future<String?> awaitingCode(String token) async => (await awaiting(token))?.$1;

  /// [awaitingCode] with the epoch of the password step. A value in another format = none.
  static Future<(String, int)?> awaiting(String token) async {
    if (!validToken(token)) return null;
    final v = await Redis.get('2fa:${hashToken(token)}');
    // 0.2.0 stored just the login (never starts with '[') — rolling restart; the epoch is the current one
    if (v != null && !v.startsWith('[')) return (v, await _epoch(v));
    try {
      final l = v == null ? null : jsonDecode(v);
      return l is List && l.length == 2 && l[0] is String && l[1] is int ? (l[0] as String, l[1] as int) : null;
    } on FormatException {
      return null;
    }
  }

  static Future<void> endAwaiting(String token) async {
    if (validToken(token)) await Redis.del('2fa:${hashToken(token)}');
  }

  /// Reads a session from Redis (null = none/not signed in).
  static Future<Session?> get(String? token) async {
    if (!validToken(token)) return null;
    final u = await Redis.get('sess:${hashToken(token!)}');
    if (u == null) return null;
    try {
      final v = jsonDecode(u);
      if (v is List && v.length == 2 && v[0] is String && v[1] is int) return Session(v[0] as String, v[1] as int);
    } on FormatException {/* a session from before epochs: just the login */}
    return Session(u);
  }

  /// Sign-out — removes the token from Redis.
  static Future<void> destroy(String? token) async {
    if (validToken(token)) await Redis.del('sess:${hashToken(token!)}');
  }

  /// Ends all sessions of an account (password change, account removal). First the epoch in the database (in the request
  /// transaction) — that is what cuts the sessions off; deleting tokens in Redis only cleans up, after the request
  /// transaction ends ([Db.afterTransaction]). Tokens are collected right away: a session created later in the same request
  /// (a new token after enabling 2FA) is not lost in the cleanup, and a parallel sign-in before COMMIT
  /// carries the old epoch and is rejected anyway.
  static Future<void> destroyAll(String username) async {
    await (await Db.connect()).execute(
        Sql.named('UPDATE users SET session_epoch = session_epoch + 1 WHERE username=@u'),
        parameters: {'u': username});
    List<String> tokens;
    try {
      tokens = await Redis.smembers('sessuser:$username');
    } catch (_) {
      return; // Redis down → the epoch rejects old tokens anyway
    }
    if (tokens.isEmpty) return;
    await Db.afterTransaction(() async {
      try {
        await Redis.delMany([for (final t in tokens) 'sess:$t']);
        await Redis.cmd(['SREM', 'sessuser:$username', ...tokens]);
      } catch (_) {/* Redis down → the epoch rejects old tokens anyway */}
    });
  }
}
