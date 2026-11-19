// ============================================================================
//  db.dart — Postgres connection pool (the Ignis relational database)
// ----------------------------------------------------------------------------
//  The database runs on a separate host. The node connects over the network. Configured
//  through environment variables. The password is REQUIRED — a missing env var stops startup
//  instead of quietly connecting with a default.
//
//  A POOL, not one connection: the driver serializes queries on a connection, so
//  one long transaction (creating a service = ~80 INSERTs) used to block all
//  requests of the node. Pool has the same API (execute/runTx), so the rest of the code does not care.
//
//  SECURITY: Postgres is NEVER public. It listens only on an
//  interface reachable by the nodes, and pg_hba + firewall let in only
//  node addresses from the private network (LAN/VPN). For traffic outside the trusted network,
//  TLS with certificate verification: IGNIS_DB_SSL=verify-full (`require` encrypts without
//  verification). Storage: IGNIS_S3_SSL=1, Redis: IGNIS_REDIS_TLS=1.
// ============================================================================

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:bcrypt/bcrypt.dart';
import 'package:postgres/postgres.dart';

import 'i18n.dart';

/// Database session as seen by domain code. Three variants, one API:
///   • REQUEST TRANSACTION with a service context (`ignis.service` set locally in the transaction) — RLS,
///   • SYSTEM context ([Db.asSystem] — a transaction; [Db.asSystemSession] — a connection: schema,
///     seed, CLI) — full view, explicitly,
///   • pool without context — tables with RLS return 0 rows (fail-closed).
///
/// Request and system sessions are closed in `finally` — code that outlived the request (an un-awaited
/// Future, a timer) gets an exception instead of someone else's or a reset connection.
class DbSession {
  DbSession._poolRef(this._poolRef) : _connection = null, _context = null;
  DbSession._connection(this._connection) : _poolRef = null, _context = null;
  DbSession._lazy(Pool pool, String context) : _poolRef = pool, _connection = null, _context = context;

  /// Pool: no context ([_context] == null), or the connection source of the lazy transaction.
  final Pool? _poolRef;
  final Connection? _connection;

  /// Context of the lazy transaction (`ignis.service`). The transaction starts on the FIRST query, not at
  /// the start of the request — a page without queries pays no BEGIN/set_config/COMMIT and holds no connection.
  final String? _context;
  Future<TxSession>? _opening;
  Completer<Object?>? _done;
  Future<void>? _result;
  bool _closed = false;
  int _points = 0;
  final _afterEnd = <Future<void> Function()>[];
  final _afterCommit = <Future<void> Function()>[];
  Future<void> _raisedChain = Future.value();
  int _raised = 0;

  /// The open transaction wrote a @Cached entity — its reads bypass the Redis mirror until it ends.
  bool _cachedWrites = false;

  /// Whether queries run with an explicit context (request or system).
  bool get inContext => _context != null || _connection != null;

  void _alive() {
    if (_closed) throw StateError('Database session used after the request/job that opened it ended');
  }

  void _notRaised(String method) {
    if (_raised > 0) {
      throw StateError('Db.$method() inside Db.asSystem/Db.asPlatform would end the transaction the elevated '
          'block runs in; call it before or after the block');
    }
  }

  Future<Session> _session() async {
    _alive();
    if (_context != null) return _tx();
    return _connection ?? _poolRef!;
  }

  /// Called in the same synchronous step that puts a query on the wire (after every `await`, also the one opening
  /// the transaction): while the transaction runs with the elevated context only code inside the running block may
  /// query.
  void _notOutsideRaised() {
    if (_raised == 0) return;
    final z = Zone.current[Db._raisedKey];
    if (z is! _RaisedBlock || !z.active || !identical(z.session, this)) {
      throw StateError('A request query ran while Db.asSystem/Db.asPlatform held the elevated context of the same '
          'transaction (Future.wait or an un-awaited future); await the elevated block before other queries');
    }
  }

  /// Transaction of the lazy session — opened once, on first use.
  Future<TxSession> _tx() => _opening ??= () {
        final ready = Completer<TxSession>();
        final end = _done = Completer<Object?>();
        var acquired = false;
        _result = _poolRef!.runTx((tx) async {
          acquired = true;
          await tx.execute(r"SELECT set_config('" + Db.serviceGuc + r"', $1, true)", parameters: [_context]);
          ready.complete(tx);
          // the request error arrives as a value: completeError without a listener (the pool has not returned
          // the connection yet) would reach the request zone as unhandled
          if (await end.future case final error?) throw error;
        }).then((_) {}, onError: (Object e, StackTrace st) {
          // no pool connection within connectTimeout: the node is saturated — 503 with Retry-After, not 500
          final overloaded = !acquired && e is TimeoutException;
          if (!ready.isCompleted) ready.completeError(overloaded ? const Overloaded() : e, st);
          throw e;
        });
        _result!.ignore(); // [_finish] takes the error; without this it would leak as unhandled
        return ready.future;
      }();

  /// COMMIT ([error] == null) or ROLLBACK of the open transaction and return of the connection to the pool.
  /// The next query (if the session is alive) opens a new transaction.
  Future<void> _finish([Object? error]) async {
    final end = _done, result = _result;
    _opening = null;
    _done = null;
    _result = null;
    _points = 0;
    _cachedWrites = false;
    if (end == null) return;
    end.complete(error);
    var committed = false;
    try {
      await result;
      committed = error == null;
    } catch (_) {
      if (error == null) rethrow; // a failed COMMIT is a request error; after ROLLBACK [error] counts
    } finally {
      final tasks = [..._afterEnd, if (committed) ..._afterCommit];
      _afterEnd.clear();
      _afterCommit.clear();
      for (final z in tasks) {
        try {
          await z();
        } catch (e) {
          stderr.writeln('Ignis: after-commit job — $e');
        }
      }
    }
  }

  Future<Result> execute(
    Object query, {
    Object? parameters,
    bool ignoreRows = false,
    QueryMode? queryMode,
    Duration? timeout,
  }) async {
    final s = await _session();
    _notOutsideRaised();
    return s.execute(query, parameters: parameters, ignoreRows: ignoreRows, queryMode: queryMode, timeout: timeout);
  }

  /// In a request transaction — a savepoint: an error in [fn] rolls back only its changes, and the rest
  /// of the request can go on (e.g. an audit log entry whose error is caught).
  Future<R> runTx<R>(Future<R> Function(TxSession session) fn,
      {TransactionSettings? settings}) async {
    final s = await _session();
    _notOutsideRaised();
    if (s is! TxSession) {
      return s is Pool ? s.runTx(fn, settings: settings) : (s as Connection).runTx(fn, settings: settings);
    }
    final point = 'ignis_${_points++}';
    await s.execute('SAVEPOINT $point');
    try {
      _notOutsideRaised();
    } catch (_) {
      // RELEASE, not ROLLBACK TO: the block's set_config sent after the SAVEPOINT must stay
      await s.execute('RELEASE SAVEPOINT $point');
      rethrow;
    }
    try {
      final r = await fn(s);
      await s.execute('RELEASE SAVEPOINT $point');
      return r;
    } catch (_) {
      await s.execute('ROLLBACK TO SAVEPOINT $point');
      rethrow;
    }
  }
}

/// A running Db.asSystem/Db.asPlatform block inside a transaction — the zone value of its body. A future that
/// outlives the block sees [active] == false and is treated as top-level.
class _RaisedBlock {
  _RaisedBlock(this.session, this.value);
  final DbSession session;
  final String value;
  bool active = true;

  /// Queue of the blocks nested in this one.
  Future<void> chain = Future.value();
}

/// Too much concurrent work (e.g. the bcrypt queue is full) — the engine answers 503 with `Retry-After`.
class Overloaded implements Exception {
  const Overloaded();
  @override
  String toString() => 'Overloaded: node overloaded';
}

class Db {
  static Pool? _pool;

  /// Zone key of the context — the connection bound to the current request.
  static const _key = #ignisDbSession;

  /// Name of the Postgres session variable the RLS policies use.
  static const serviceGuc = 'ignis.service';

  /// "Nobody" hash — bcrypt runs for a non-existent login as well, so the response
  /// time does not reveal which accounts exist. A constant with cost [bcryptCost]: computed lazily it
  /// stalled the main isolate for ~250 ms, and in a fresh isolate (Isolate.run) it cost two bcrypts instead of one.
  static const emptyHash = r'$2a$12$U78a1F1jTwCuU59gQBsOLOKSS3/XjGs8/mL3usuZsVFVJhbhojQ/q';

  /// bcrypt in an isolate, at most [bcryptWorkers] at once (`IGNIS_BCRYPT_THREADS`, CPU count by default) and at most
  /// [bcryptQueue] waiting — beyond that [Overloaded] (503) instead of an unbounded number of isolates.
  static Future<T> bcrypt<T>(T Function() f) async {
    if (_bcryptRunning >= bcryptWorkers) {
      if (_bcryptWaiting.length >= bcryptQueue) throw const Overloaded();
      final c = Completer<void>();
      _bcryptWaiting.add(c);
      await c.future;
    } else {
      _bcryptRunning++;
    }
    try {
      return await Isolate.run(f);
    } finally {
      // the slot goes straight to the first waiter — the counter stays
      if (_bcryptWaiting.isNotEmpty) {
        _bcryptWaiting.removeFirst().complete();
      } else {
        _bcryptRunning--;
      }
    }
  }

  static int bcryptWorkers = int.tryParse(Platform.environment['IGNIS_BCRYPT_THREADS'] ?? '') ?? Platform.numberOfProcessors;
  static int bcryptQueue = 64;
  static int _bcryptRunning = 0;
  static final _bcryptWaiting = Queue<Completer<void>>();

  /// bcrypt cost of new hashes. Older ones (lower cost) are rehashed on a successful sign-in (SEC-A-17).
  static const bcryptCost = 12;

  /// One password rule for every path (panel, customers, seed, CLI): i18n key of the error, null = fine.
  static String? passwordErrorKey(String password) => password.length < 10
      ? 'ignis.msg.password.too_short'
      : passwordTooLong(password) ? 'ignis.msg.password.too_long' : null;

  /// [passwordErrorKey] as English text (CLI, logs, API without a page language).
  static String? passwordError(String password) => switch (passwordErrorKey(password)) {
        null => null,
        final k => I18n.t('en', k),
      };

  /// Whether the hash has a lower cost than [bcryptCost] (`$2a$10$…`).
  static bool weakHash(String hash) => (int.tryParse(hash.split(r'$').elementAtOrNull(2) ?? '') ?? 0) < bcryptCost;

  static String _required(String key) =>
      Platform.environment[key] ??
      (throw StateError('Missing $key — the node will not start without it'));

  /// Connection pool from environment variables:
  ///   IGNIS_DB_HOST (required)
  ///   IGNIS_DB_PORT (5432), IGNIS_DB_NAME (ignis),
  ///   IGNIS_DB_USER (ignis), IGNIS_DB_PASS (required), IGNIS_DB_POOL (16)
  /// Session of the current request/system job (if any), or the pool without context.
  static Future<DbSession> connect() async {
    final z = Zone.current[_key];
    if (z is DbSession) return z;
    return DbSession._poolRef(await pool());
  }

  /// Runs [body] in ONE transaction with the service context set LOCALLY
  /// (`set_config(..., true)`): the context dies with COMMIT/ROLLBACK, so the connection returns
  /// to the pool clean, also behind PgBouncer in transaction mode. The policy reads
  /// `current_setting('ignis.service')`, so a forgotten `WHERE service` will not show other tenants' data.
  /// An exception from [body] rolls the transaction back.
  static Future<T> inContext<T>(int service, Future<T> Function() body) => _inTransaction('$service', body);

  static Future<T> _inTransaction<T>(String value, Future<T> Function() body) async {
    final session = DbSession._lazy(await pool(), value);
    final T result;
    try {
      result = await runZoned(body, zoneValues: {_key: session});
    } catch (e) {
      session._closed = true;
      await session._finish(e);
      rethrow;
    }
    session._closed = true;
    await session._finish();
    return result;
  }

  /// The current lazy transaction (request or [asSystem]), or null.
  static DbSession? get _lazy {
    final z = Zone.current[_key];
    return z is DbSession && !z._closed && z._context != null ? z : null;
  }

  /// Returns the connection of the current transaction before a long operation without the database (bcrypt), as long as
  /// the transaction has not written anything yet — then COMMIT does not change the meaning of the request. With writes it does
  /// nothing (atomicity matters more than the connection). The next query opens a new transaction.
  static Future<void> release() async {
    final s = _lazy;
    s?._notRaised('release');
    if (s?._opening == null) return;
    final clean = (await s!.execute('SELECT txid_current_if_assigned() IS NULL')).first[0] == true;
    if (clean) await s._finish();
  }

  /// [task] after the current transaction ends (COMMIT or ROLLBACK), or right away without an open transaction.
  /// For effects outside the database that must see the state AFTER the write: dropping the permission cache before COMMIT
  /// let a parallel request rebuild it from old data (for 900 s), and ending sessions before
  /// COMMIT let someone sign in with the old password and keep the session. After ROLLBACK too: dropping the cache and ending
  /// sessions break nothing, and closing sessions after too many wrong passwords must happen even when the request fails.
  /// With [onlyAfterCommit] the task is dropped after ROLLBACK (e.g. a cache write of data that never existed).
  static Future<void> afterTransaction(Future<void> Function() task, {bool onlyAfterCommit = false}) async {
    final s = _lazy;
    if (s?._opening == null) return task();
    (onlyAfterCommit ? s!._afterCommit : s!._afterEnd).add(task);
  }

  /// Marks the open transaction as having written a @Cached entity ([Orm]): until it ends, reads skip the mirror
  /// (they must see the transaction's own writes) and do not fill it with uncommitted data.
  static void noteCachedWrite() => _lazy?._cachedWrites = true;

  /// Whether the open transaction has written a @Cached entity.
  static bool get hasCachedWrites => _lazy?._cachedWrites ?? false;

  /// COMMIT of what the current transaction has done so far, and return of the connection — before a transfer to storage.
  /// The rest of the request runs in a new transaction, so it is not atomic with what came before.
  static Future<void> commit() async {
    final s = _lazy;
    s?._notRaised('commit');
    await s?._finish();
  }

  /// Platform context: full view, explicitly. For places where a customer panel
  /// must reach platform data (e.g. platform settings) — better
  /// than a hole in the policy, because the code shows who leaves the tenant and why.
  /// Inside an open context — on THE SAME connection (a second one from the pool while holding the first
  /// deadlocked the pool under load; PERF-A-3).
  static Future<T> asPlatform<T>(Future<T> Function() body) {
    final z = Zone.current[_key];
    if (z is DbSession && !z._closed && z._connection != null) return body(); // '*' includes '0'
    if (z is DbSession && !z._closed && z._context != null) return _briefly(z, '0', body);
    return inContext(0, body);
  }

  /// [body] with context [value] set locally in the transaction of session [s]; then the request context returns.
  /// The context covers the whole request transaction, so a query launched IN PARALLEL with [body] from outside it
  /// (Future.wait, un-awaited future) throws [StateError] ([DbSession._notOutsideRaised]) — always `await` a raised block
  /// before the rest (SECURITY.md, "Notes for app authors"). Raised blocks of one session run one after another, so an
  /// overlapping block cannot restore a context it read while another block was raised. Blocks nested in a
  /// still running block queue on that block and restore its context; a future that outlives its block counts
  /// as top-level. Waiting in a queue longer than [_raisedWait] (a block awaiting a future that itself waits
  /// for the queue) ends with a [StateError] instead of hanging.
  static Future<T> _briefly<T>(DbSession s, String value, Future<T> Function() body) async {
    final z = Zone.current[_raisedKey];
    final parent = z is _RaisedBlock && z.active && identical(z.session, s) ? z : null;
    final restore = parent?.value ?? s._context!;
    final previous = parent?.chain ?? s._raisedChain, turn = Completer<void>();
    if (parent != null) {
      parent.chain = turn.future;
    } else {
      s._raisedChain = turn.future;
    }
    try {
      await previous.timeout(_raisedWait);
    } on TimeoutException {
      previous.whenComplete(turn.complete).ignore();
      throw StateError('Db.asSystem/Db.asPlatform waited over ${_raisedWait.inSeconds} s for another elevated '
          'block of the same transaction — a block probably awaits a future that waits for the block itself');
    }
    try {
      return await _raise(s, value, restore, body);
    } finally {
      turn.complete();
    }
  }

  static const _raisedKey = #ignisRaised;
  static const _raisedWait = Duration(seconds: 30);

  static Future<T> _raise<T>(DbSession s, String value, String restore, Future<T> Function() body) async {
    final tx = await s._tx();
    Future<void> set(String v) => tx.execute(r"SELECT set_config('" + serviceGuc + r"', $1, true)", parameters: [v]);
    // raised before set_config goes on the wire: a query from outside sent after it would run elevated
    s._raised++;
    final block = _RaisedBlock(s, value);
    final T result;
    try {
      if (value != restore) await set(value);
      result = await runZoned(body, zoneValues: {_raisedKey: block});
    } catch (_) {
      block.active = false;
      await block.chain;
      // an aborted transaction refuses set_config; the body's error is the one to report, and the transaction
      // (or the caller's savepoint, which also undoes the raised context) is rolled back anyway
      try {
        if (value != restore) await set(restore);
      } catch (_) {}
      s._raised--;
      rethrow;
    }
    block.active = false;
    // nested blocks started (not awaited) in [body] restore this block's context — they end first
    await block.chain;
    try {
      if (value != restore) await set(restore);
    } finally {
      s._raised--;
    }
    return result;
  }

  /// SYSTEM context (`ignis.service = '*'`): everything that by design sees every service
  /// (domain lookup, cleanup, app code outside a request). Without it a query on a table
  /// with RLS returns 0 rows. Inside an already open context — the same one.
  ///
  /// In ONE transaction with `set_config(..., true)`: the context dies with COMMIT/ROLLBACK, so behind PgBouncer
  /// in transaction mode no server connection is left with `'*'`. A statement error aborts the rest of
  /// [body] — code that wants to survive it uses `runTx` (savepoint).
  static Future<T> asSystem<T>(Future<T> Function() body) {
    final z = Zone.current[_key];
    if (z is DbSession && !z._closed && z._connection != null) return body();
    // in a request transaction: '*' locally for [body], then the request context returns
    if (z is DbSession && !z._closed && z._context != null) return _briefly(z, '*', body);
    return _inTransaction('*', body);
  }

  /// [asSystem] per SESSION, without a transaction — only schema, seed and CLI scripts: they catch errors of single
  /// statements (DDL on data that breaks a constraint) and go on, and the CLI ends with `exit()` midway.
  /// `set_config(..., false)` lives on the server connection, so it needs a DIRECT connection to Postgres
  /// (not through a transaction pooler). The context is cleared in `finally`; if that fails, the exception makes the pool
  /// discard the connection instead of returning it with `'*'`.
  static Future<T> asSystemSession<T>(Future<T> Function() body) async {
    final z = Zone.current[_key];
    if (z is DbSession && !z._closed && z._connection != null) return body();
    if (z is DbSession && !z._closed && z._context != null) return _briefly(z, '*', body);
    return (await pool()).withConnection((c) async {
      await _setContext(c, '*');
      final session = DbSession._connection(c);
      try {
        return await runZoned(body, zoneValues: {_key: session});
      } finally {
        session._closed = true;
        await _setContext(c, '');
      }
    });
  }

  static Future<void> _setContext(Connection c, String value) => c.execute(
        r"SELECT set_config('" + serviceGuc + r"', $1, false)",
        parameters: [value],
      );

  /// Closes the pool (graceful node shutdown).
  static Future<void> close() async {
    final p = _pool;
    _pool = null;
    await p?.close();
  }

  static Future<Pool> pool() async {
    if (_pool != null) return _pool!;
    final env = Platform.environment;
    _pool = Pool.withEndpoints(
      [
        Endpoint(
          host: _required('IGNIS_DB_HOST'),
          port: int.parse(env['IGNIS_DB_PORT'] ?? '5432'),
          database: env['IGNIS_DB_NAME'] ?? 'ignis',
          username: env['IGNIS_DB_USER'] ?? 'ignis',
          password: _required('IGNIS_DB_PASS'),
        ),
      ],
      settings: PoolSettings(
        // A request holds a connection from the FIRST query until processing ends (transaction with the RLS
        // context), so the pool size is the limit of concurrent requests in the database. bcrypt and storage transfers
        // give it back earlier (Db.release / Db.commit).
        maxConnectionCount: int.parse(env['IGNIS_DB_POOL'] ?? '16'),
        // also the limit for waiting on a free pool connection — a full pool gives an error, not an endless queue
        connectTimeout: const Duration(seconds: 5),
        queryTimeout: const Duration(seconds: 30),
        sslMode: sslMode(env['IGNIS_DB_SSL']),
      ),
    );
    return _pool!;
  }

  /// TLS to Postgres from `IGNIS_DB_SSL`: `disable` (default, private network), `require` (encryption
  /// WITHOUT certificate verification — no protection against MitM), `verify-full` (certificate and host name
  /// against the system CAs; SEC-A-18). A typo stops startup instead of quietly disabling TLS.
  static SslMode sslMode(String? w) => switch (w ?? 'disable') {
        'disable' => SslMode.disable,
        'require' => SslMode.require,
        'verify-full' => SslMode.verifyFull,
        final x => throw StateError('IGNIS_DB_SSL=$x — allowed: disable | require | verify-full'),
      };

  /// Checks a login: fetches the user's (bcrypt) hash and verifies the password.
  /// Returns the username on success, null for wrong credentials.
  /// bcrypt runs in a separate isolate ([bcrypt]) — 100-300 ms on the main one would block
  /// all node requests on every sign-in.
  static Future<String?> checkLogin(String username, String password) async =>
      (await checkLoginWithEpoch(username, password))?.$1;

  /// [checkLogin] plus `users.session_epoch` read in the same query as the hash — a session created with it is
  /// rejected when a password change / "sign out everywhere" commits while bcrypt runs.
  static Future<(String, int)?> checkLoginWithEpoch(String username, String password) async {
    // bcrypt takes at most 72 bytes and throws on longer input — such a password cannot match
    if (passwordTooLong(password)) return null;
    final conn = await connect();
    final rows = await conn.execute(
      // staff only: customer accounts (realm customer) have an empty hash, and bcrypt on ''
      // threw → a 500 that revealed that such a customer exists
      Sql.named("SELECT username, pass_hash, session_epoch FROM users WHERE username=@u AND realm='staff'"),
      parameters: {'u': username},
    );
    final stored = rows.isEmpty || (rows.first[1] as String).isEmpty ? emptyHash : rows.first[1] as String;
    await release(); // bcrypt without holding a pool connection
    final ok = await bcrypt(() => BCrypt.checkpw(password, stored));
    if (rows.isEmpty || !ok) return null;
    if (weakHash(stored)) {
      final fresh = await bcrypt(() => hashPassword(password));
      await conn.execute(Sql.named('UPDATE users SET pass_hash=@h WHERE username=@u AND pass_hash=@s'),
          parameters: {'u': username, 'h': fresh, 's': stored});
    }
    return (rows.first[0] as String, rows.first[2] as int);
  }

  /// bcrypt hash of a password (for creating/changing a user).
  /// Throws [FormatException] with [passwordLengthMessage] for a password > 72 bytes.
  static String hashPassword(String password) {
    if (passwordTooLong(password)) throw const FormatException(passwordLengthMessage);
    return BCrypt.hashpw(password, BCrypt.gensalt(logRounds: bcryptCost));
  }

  /// bcrypt accepts at most 72 bytes of UTF-8.
  static bool passwordTooLong(String password) => utf8.encode(password).length > 72;
  static const passwordLengthMessage =
      'The password can be at most 72 bytes (about 72 characters; accented letters count double).';

  /// Service (tenant) the account belongs to. 0 = platform.
  /// No account → -1, i.e. "no service": it matches nothing.
  static Future<int> accountService(String username) async {
    final rows = await (await connect()).execute(
      Sql.named('SELECT service FROM users WHERE username=@u'),
      parameters: {'u': username},
    );
    return rows.isEmpty ? -1 : (rows.first[0] as int? ?? 0);
  }

  /// Random initial password (when IGNIS_ADMIN_PASS is not given).
  static String randomPassword() {
    const chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return List.generate(16, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// Account realm: 'staff' (back office) or 'customer' (customer panel).
  /// No account → 'customer', i.e. the least privileges, not the most.
  static Future<String> realm(String username) async {
    final conn = await connect();
    final rows = await conn.execute(
      Sql.named('SELECT realm FROM users WHERE username=@u'),
      parameters: {'u': username},
    );
    return rows.isEmpty ? 'customer' : (rows.first[0] as String? ?? 'customer');
  }

  /// Realm, service, password-change flag and session epoch of an account in one query.
  static Future<(String, int, bool, int)?> account(String username) async {
    final rows = await (await connect()).execute(
      Sql.named('SELECT realm, service, coalesce(must_change_password, false), session_epoch FROM users WHERE username=@u'),
      parameters: {'u': username},
    );
    if (rows.isEmpty) return null;
    return ((rows.first[0] as String?) ?? 'customer', (rows.first[1] as int?) ?? 0,
        rows.first[2] == true, rows.first[3] as int);
  }
}
