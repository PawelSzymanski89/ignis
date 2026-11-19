// ============================================================================
//  redis.dart — Redis client (shared state between nodes)
// ----------------------------------------------------------------------------
//  Redis is not public: reachable only from the nodes' private network (firewall).
//  It holds SHARED SESSIONS, the permission and domain caches and background job locks —
//  so the load balancer does round-robin and every node sees the same.
//
//  Every call has a 2 s limit. After an error the connection is dropped and the next
//  call opens a new one — without that a Redis restart meant restarting the nodes.
//
//  Environment: IGNIS_REDIS_HOST (required), IGNIS_REDIS_PORT (6379),
//               IGNIS_REDIS_PASS, IGNIS_REDIS_TLS (1 = TLS).
// ============================================================================

import 'dart:async';
import 'dart:io';

import 'package:redis/redis.dart';

class Redis {
  static RedisConnection? _rc;
  static Command? _cmd;
  static const _limit = Duration(seconds: 2);

  static Future<Command>? _connecting;

  /// Parallel calls after a disconnect wait for ONE connect — without that each opened
  /// its own and abandoned connections multiplied (PERF-A-3).
  static Future<Command> _conn() {
    if (_cmd != null) return Future.value(_cmd!);
    return _connecting ??= _connectNow().whenComplete(() => _connecting = null);
  }

  static Future<Command> _connectNow() async {
    final env = Platform.environment;
    final rc = RedisConnection();
    final host = env['IGNIS_REDIS_HOST'] ?? (throw StateError('Missing IGNIS_REDIS_HOST'));
    final port = int.parse(env['IGNIS_REDIS_PORT'] ?? '6379');
    // TLS with certificate verification (system CAs) when IGNIS_REDIS_TLS=1 (SEC-A-18)
    final cmd = await (env['IGNIS_REDIS_TLS'] == '1' ? rc.connectSecure(host, port) : rc.connect(host, port))
        .timeout(_limit);
    final pass = env['IGNIS_REDIS_PASS'];
    if (pass != null && pass.isNotEmpty) {
      await cmd.send_object(['AUTH', pass]).timeout(_limit);
    }
    _rc = rc;
    _cmd = cmd;
    return cmd;
  }

  /// One command with a time limit. Error = we drop the connection, but only THE one the command went through:
  /// commands still hanging on a dead connection finish later and would otherwise close the next,
  /// healthy ones (and the limits are fail-closed — a short outage turned into a series of sign-in refusals).
  static Future<Object?> cmd(List<Object> args) async {
    final c = await _conn();
    final rc = _rc;
    try {
      return await c.send_object(args).timeout(_limit);
    } catch (_) {
      if (identical(_cmd, c)) {
        _cmd = null;
        _rc = null;
      }
      // no waiting: closing a dead socket (the peer does not read) hangs on flushing the buffer, and the error must
      // get back to the caller within the limit
      try {
        unawaited(rc?.close().catchError((_) {}));
      } catch (_) {}
      rethrow;
    }
  }

  /// SET key val with a lifetime (seconds).
  static Future<void> setEx(String key, String value, int ttlSeconds) =>
      cmd(['SET', key, value, 'EX', ttlSeconds.toString()]);

  /// SET key val without TTL (for global @Synced — lives as long as the system).
  static Future<void> set(String key, String value) => cmd(['SET', key, value]);

  /// GET key → value or null.
  static Future<String?> get(String key) async => (await cmd(['GET', key])) as String?;

  /// SET key val NX EX sec — take the key only if free (distributed lock).
  /// Returns true when taken; false when already taken.
  static Future<bool> setNxEx(String key, String value, int ttlSeconds) async =>
      (await cmd(['SET', key, value, 'NX', 'EX', ttlSeconds.toString()])) != null;

  /// INCR key → new value (atomic counter, e.g. of sign-in attempts).
  static Future<int> incr(String key) async => (await cmd(['INCR', key])) as int;

  /// Counter in a [window] s window: INCR and EXPIRE atomically (Lua) — a crash between them will not leave
  /// a counter without TTL, i.e. an eternal lock.
  static Future<int> counter(String key, int window) async => (await cmd([
        'EVAL',
        "local n = redis.call('INCR', KEYS[1]) if n == 1 then redis.call('EXPIRE', KEYS[1], ARGV[1]) end return n",
        '1',
        key,
        '$window',
      ])) as int;

  /// EXPIRE key sec — set a TTL on the key.
  static Future<void> expire(String key, int seconds) =>
      cmd(['EXPIRE', key, seconds.toString()]);

  /// DEL key (e.g. sign-out).
  static Future<void> del(String key) => cmd(['DEL', key]);

  /// Releases `lock:*` locks held by [node] (value == node name) — on
  /// shutdown, so background jobs start on another node without waiting for the TTL.
  /// SCAN in batches, not KEYS — KEYS blocked Redis (and the sessions of all nodes) for the duration of the scan.
  static Future<void> releaseLocks(String node) async {
    var cursor = '0';
    do {
      final r = (await cmd(['SCAN', cursor, 'MATCH', 'lock:*', 'COUNT', '500'])) as List;
      cursor = '${r[0]}';
      final keys = (r[1] as List).cast<String>();
      if (keys.isEmpty) continue;
      await cmd([
        'EVAL',
        "for _, k in ipairs(KEYS) do if redis.call('GET', k) == ARGV[1] then redis.call('DEL', k) end end",
        '${keys.length}',
        ...keys,
        node,
      ]);
    } while (cursor != '0');
  }

  /// DEL of many keys in one command.
  static Future<void> delMany(List<String> keys) async {
    if (keys.isNotEmpty) await cmd(['DEL', ...keys]);
  }

  /// SADD key member.
  static Future<void> sadd(String key, String member) => cmd(['SADD', key, member]);

  /// SMEMBERS key → list.
  static Future<List<String>> smembers(String key) async =>
      ((await cmd(['SMEMBERS', key])) as List? ?? const []).cast<String>();
}
