// ============================================================================
//  redis.dart — Redis client (shared state between nodes)
// ----------------------------------------------------------------------------
//  Redis is not public: reachable only from the nodes' private network (firewall).
//  It holds SHARED SESSIONS, the permission and domain caches and background job locks —
//  so the load balancer does round-robin and every node sees the same.
//
//  Every call has a 2 s limit. After a timeout or a socket error the connection is dropped and the next
//  call opens a new one — without that a Redis restart meant restarting the nodes. An error reply from the
//  server (-ERR, -NOAUTH …, a RedisError) goes to the caller and keeps the connection.
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

  /// One command with a time limit. An error reply from the server ([RedisError]) is rethrown and the connection
  /// kept — the socket is fine, and dropping it meant a new TCP connection per failed command.
  /// Timeout / socket error = we drop the connection, but only THE one the command went through:
  /// commands still hanging on a dead connection finish later and would otherwise close the next,
  /// healthy ones (and the limits are fail-closed — a short outage turned into a series of sign-in refusals).
  static Future<Object?> cmd(List<Object> args) async {
    final c = await _conn();
    final rc = _rc;
    try {
      return await c.send_object(args).timeout(_limit);
    } on RedisError {
      rethrow;
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

  /// Owner prefix of this process's lock values: `IGNIS_NODE`, or — when it is unset/empty — a random id generated
  /// once per process (`hostname-pid-random`), so nodes without `IGNIS_NODE` never share the prefix `node` and
  /// [releaseLocks] of one never deletes another's locks. Only for lock ownership; the displayed node name is
  /// still `IGNIS_NODE`.
  static final String lockNode = _lockNode();
  static String _lockNode() {
    final env = Platform.environment['IGNIS_NODE'] ?? '';
    if (env.isNotEmpty) return env;
    String host;
    try {
      host = Platform.localHostname;
    } catch (_) {
      host = 'host';
    }
    // no ':' — it separates the prefix from the run token
    return '${host.replaceAll(':', '_')}-$pid-${Crypto.randomToken(4)}';
  }

  /// Runs [body] while holding the lease `lock:[name]`. Returns false (body not run) when another run holds it.
  ///
  /// Contract:
  /// - **Lease, not a mutex.** The lock is a Redis key with a per-run token `node:<random>` and a TTL of [ttl],
  ///   renewed every ttl/3 (keep-alive). When a renewal finds the key gone or taken over, or Redis fails,
  ///   `stillOwner()` turns false for good; another node may then take the lock and run concurrently.
  /// - **[maxRun] is not a timeout.** [body] is never interrupted. After [maxRun] `stillOwner()` turns false,
  ///   the keep-alive stops and the lock expires after at most [ttl]; [body] must notice and stop on its own.
  /// - **No atomicity between check and write.** `stillOwner()` (last keep-alive result) and [confirmExclusive]
  ///   (a fresh check in Redis) only narrow the window: the lease can be lost right after a check returns true
  ///   (a pause, a slow write). Correctness must come from the resource itself — idempotent effects or a
  ///   conditional write (unique key, version / state column checked in the UPDATE).
  /// - **Only the owner releases or extends.** Renewal is compare-and-expire ([expireIfEqual]) and the release
  ///   in finally is compare-and-delete ([delIfEqual]) with this run's token, so a run never touches a lock
  ///   another run took after its lease expired.
  /// - **At-least-once, not exactly-once; no fencing token.** After a lost lease two runs can overlap, and a
  ///   stage the old run started before the pause still completes. Give every effect a deterministic id
  ///   (idempotency key, an execution ledger row with a unique key, or dedup at read — e.g. ReplacingMergeTree
  ///   + FINAL) and reconcile instead of relying on the lock. A fencing token is not provided: it only helps
  ///   when the target checks it atomically with the write, and the typical targets (push providers, mail,
  ///   HTTP APIs) cannot.
  /// - [body] errors propagate after the release.
  ///
  /// ```dart
  /// await Redis.runExclusive('invoices', const Duration(seconds: 60), (stillOwner) async {
  ///   for (final batch in batches) {
  ///     if (!stillOwner() || !await Redis.confirmExclusive('invoices')) return; // before each batch
  ///     await sendBatch(batch); // idempotent: UPDATE … SET sent = true WHERE id = @id AND NOT sent
  ///   }
  /// });
  /// ```
  static Future<bool> runExclusive(
      String name, Duration ttl, Future<void> Function(bool Function() stillOwner) body, {Duration? maxRun}) async {
    final key = 'lock:$name';
    final token = '$lockNode:${Crypto.randomToken(8)}';
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
    final limit = maxRun == null
        ? null
        : Timer(maxRun, () {
            if (!owner) return;
            owner = false;
            stderr.writeln('Ignis job $name — exceeded maxRun $maxRun; no longer owner, the lock expires after $ttl');
          });
    final done = Completer<void>();
    final run = _Run(token, () => owner = false, done.future);
    _runs.add(run);
    try {
      await body(() => owner);
    } finally {
      beat.cancel();
      limit?.cancel();
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
