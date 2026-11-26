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

import 'crypto.dart';

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

  /// Compare-and-delete: DEL [key] only when it still holds [value]. Returns true when deleted.
  /// For a lock whose owner must not drop a lock another node took over after the TTL expired — pass a value
  /// unique PER RUN (not just the node name, or two runs of the same node could not tell their locks apart).
  static Future<bool> delIfEqual(String key, String value) async =>
      (await cmd([
            'EVAL',
            "if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) end return 0",
            '1',
            key,
            value,
          ])) == 1;

  /// Compare-and-expire: EXPIRE [key] only when it still holds [value] (extend one's OWN lock, never a lock
  /// another node took over). Returns true when the TTL was set.
  static Future<bool> expireIfEqual(String key, String value, int seconds) async =>
      (await cmd([
            'EVAL',
            "if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('EXPIRE', KEYS[1], ARGV[2]) end return 0",
            '1',
            key,
            value,
            seconds.toString(),
          ])) == 1;

  /// Runs [body] on at most one node at a time under the lock `lock:[name]`. Returns false (body not run) when
  /// another run holds it. The lock is taken with a per-run token `node:<random>` and kept alive every ttl/3
  /// (compare-and-expire); when the keep-alive finds the lock gone or taken over (or Redis fails), `stillOwner()`
  /// turns false for good and [body] should stop at its next check. Released in finally only if still ours.
  /// [body] errors propagate after the release.
  static Future<bool> runExclusive(
      String name, Duration ttl, Future<void> Function(bool Function() stillOwner) body) async {
    final key = 'lock:$name';
    final token = '${Platform.environment['IGNIS_NODE'] ?? 'node'}:${Crypto.randomToken(8)}';
    final seconds = ttl.inSeconds < 1 ? 1 : ttl.inSeconds;
    if (!await setNxEx(key, token, seconds)) return false;
    var owner = true;
    var beating = false;
    _confirms[name] = () async {
      try {
        if (owner && !await expireIfEqual(key, token, seconds)) owner = false;
      } catch (_) {
        owner = false;
      }
      return owner;
    };
    final beat = Timer.periodic(Duration(milliseconds: seconds * 1000 ~/ 3), (_) async {
      if (!owner || beating) return;
      beating = true;
      try {
        if (!await expireIfEqual(key, token, seconds)) owner = false;
      } catch (_) {
        owner = false; // ownership unknown — fail safe, the TTL may run out meanwhile
      } finally {
        beating = false;
      }
    });
    final done = Completer<void>();
    final run = _Run(token, () => owner = false, done.future);
    _runs.add(run);
    try {
      await body(() => owner);
    } finally {
      beat.cancel();
      _confirms.remove(name);
      _runs.remove(run);
      try {
        await delIfEqual(key, token);
      } catch (_) {} // the TTL frees it anyway
      done.complete();
    }
    return true;
  }

  static final _confirms = <String, Future<bool> Function()>{};
  static final _runs = <_Run>{};

  /// Shutdown: turns `stillOwner()` (and [confirmExclusive]) false for every [runExclusive] run active in this
  /// isolate and waits up to [wait] for them to finish (each releases its own lock). Returns the lock tokens of
  /// runs still going after [wait] — pass them to [releaseLocks] as `keep`, or another node would take the lock
  /// and run the same job alongside (their TTL frees them later).
  static Future<List<String>> abandonExclusive({Duration wait = const Duration(seconds: 10)}) async {
    final runs = _runs.toList();
    for (final r in runs) {
      r.revoke();
    }
    if (runs.isEmpty) return const [];
    await Future.wait([for (final r in runs) r.done]).timeout(wait, onTimeout: () => const []);
    return [for (final r in _runs) r.token];
  }

  /// Direct ownership check for a [runExclusive] run of [name] in this isolate: compare-and-expire in Redis now
  /// (not the keep-alive's last result). Use before each side-effecting batch of a long run. False when no run
  /// of [name] is active here or the lock is gone / taken over (then `stillOwner()` turns false too).
  static Future<bool> confirmExclusive(String name) => _confirms[name]?.call() ?? Future.value(false);

  /// DEL key (e.g. sign-out).
  static Future<void> del(String key) => cmd(['DEL', key]);

  /// Releases `lock:*` locks held by [node] — on shutdown, so background jobs start on another node without
  /// waiting for the TTL. Matches both the value == node name (plain locks) and the value `node:<run token>`
  /// (locks taken with a per-run token via [delIfEqual]), except values in [keep] (runs still going, see
  /// [abandonExclusive]).
  /// SCAN in batches, not KEYS — KEYS blocked Redis (and the sessions of all nodes) for the duration of the scan.
  static Future<void> releaseLocks(String node, {Iterable<String> keep = const []}) async {
    var cursor = '0';
    do {
      final r = (await cmd(['SCAN', cursor, 'MATCH', 'lock:*', 'COUNT', '500'])) as List;
      cursor = '${r[0]}';
      final keys = (r[1] as List).cast<String>();
      if (keys.isEmpty) continue;
      await cmd([
        'EVAL',
        "local p = ARGV[1] .. ':' local keep = {} for i = 2, #ARGV do keep[ARGV[i]] = true end "
            "for _, k in ipairs(KEYS) do local v = redis.call('GET', k) "
            "if v and not keep[v] and (v == ARGV[1] or v:sub(1, #p) == p) then redis.call('DEL', k) end end",
        '${keys.length}',
        ...keys,
        node,
        ...keep,
      ]);
    } while (cursor != '0');
  }

  /// DEL of many keys, one DEL per key (sent together): on Redis Cluster a multi-key DEL across hash slots fails
  /// with CROSSSLOT.
  static Future<void> delMany(List<String> keys) async {
    await Future.wait([for (final k in keys) del(k)]);
  }

  /// SADD key member.
  static Future<void> sadd(String key, String member) => cmd(['SADD', key, member]);

  /// SMEMBERS key → list.
  static Future<List<String>> smembers(String key) async =>
      ((await cmd(['SMEMBERS', key])) as List? ?? const []).cast<String>();
}

class _Run {
  _Run(this.token, this.revoke, this.done);
  final String token;
  final void Function() revoke;
  final Future<void> done;
}
