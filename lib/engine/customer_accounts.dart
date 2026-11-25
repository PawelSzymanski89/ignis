// ============================================================================
//  customer_accounts.dart — sign-in of site customers (front, not the panel)
// ----------------------------------------------------------------------------
//  Customer account = a `users` row with realm `customer`, login = e-mail:
//    • password set by an admin (bcrypt like panel accounts),
//    • password reset: a one-time token from an e-mail (1 h), only its SHA-256 in Redis; it also expires after a password change,
//    • session token in Redis with `users.session_epoch`; a password change bumps the epoch, which ends every session,
//  Session in a separate cookie (`ignis_customer`), never in the panel one — a customer
//  account has no way into the back office, because the back office reads another cookie.
//  The account is just an e-mail — what the customer sees after sign-in is added by the app.
// ============================================================================

import 'dart:convert';
import 'dart:math';

import 'package:bcrypt/bcrypt.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:postgres/postgres.dart' show Sql, TypedValue;
import 'package:postgres/postgres.dart' as pg show Type;

import 'db.dart';
import 'client_ip.dart';
import 'redis.dart';
import 'session.dart' show Sessions;

class CustomerSession {
  CustomerSession(this.email, this.service);
  final String email;
  final int service;
}

class CustomerAccounts {
  static const cookie = '__Host-ignis_customer'; // like Sessions.cookieName (SEC-A-13)
  static const _ttl = 60 * 60 * 24 * 30; // a month — a customer does not sign in on every visit
  static final _rnd = Random.secure();
  // disjoint classes (dot only as a separator) — no n² backtracking on `a@....@` (SEC-A-10)
  static final _email = RegExp(r'^[^@\s]+@[^@\s.]+(\.[^@\s.]+)+$');

  static String _token([int n = 24]) =>
      List.generate(n, (_) => _rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  static bool validEmail(String e) => e.length <= 254 && _email.hasMatch(e);

  /// "Where to after sign-in" address — only a path on this site. `//evil.example`
  /// also starts with `/`, and the browser takes it for a scheme-relative address.
  static String safeNext(String? d, [String defaultOne = '/account']) =>
      d != null && _next.hasMatch(d) ? d : defaultOne;

  // the browser strips TAB/CR/LF from the address and treats `\` as `/`: `/<TAB>/evil` becomes `//evil`
  static final _next = RegExp(r'^/(?![/\\])[^\x00-\x20\x7f\\]*$');

  /// Soft per-account limit, across addresses (botnet, many /64s): above [accountThreshold] attempts per hour each
  /// next one waits [accountDelay] — no hard lock a stranger could use to close someone else's account.
  static const accountThreshold = 30;
  static const accountDelay = Duration(seconds: 3);
  static Future<void> releaseUnderAttack(String key) async {
    if (await overLimit(key, accountThreshold, 3600)) await Future<void>.delayed(accountDelay);
  }

  /// Windowed counter in Redis; true = over the limit. Fail-closed: without Redis the limit does not work,
  /// and sessions need it anyway — "denied" instead of an unlimited password oracle (SEC-A-9).
  static Future<bool> overLimit(String key, int limit, int window) async => await attempts(key, window) > limit;

  /// Attempt count in the window (after this one). Without Redis — [noCounter], i.e. "over any limit" (fail-closed).
  static Future<int> attempts(String key, int window) async {
    try {
      return await Redis.counter(key, window);
    } catch (_) {
      return noCounter;
    }
  }

  static const noCounter = 1 << 30;

  /// The `users` row of a service customer account.
  static String accountLogin(int service, String email) => 'c:$service:${email.trim().toLowerCase()}';

  static String? passwordError(String password) => Db.passwordError(password);

  /// An account without a password (link/SSO) runs bcrypt on a dummy — timing does not reveal which accounts have a password.
  static bool passwordMatches(String password, String hash) {
    if (Db.passwordTooLong(password)) return false;
    final ok = BCrypt.checkpw(password, hash.isEmpty ? Db.emptyHash : hash);
    return ok && hash.isNotEmpty;
  }

  /// Password set by an admin — creates the account or replaces the password and ends the customer's sessions.
  static Future<String?> setPassword(int service, String email, String password) async {
    final e = email.trim().toLowerCase();
    if (!validEmail(e)) return 'Podaj poprawny adres e-mail.';
    final b = passwordError(password);
    if (b != null) return b;
    final h = await Db.bcrypt(() => Db.hashPassword(password));
    await (await Db.connect()).execute(
        Sql.named('''INSERT INTO users (username, pass_hash, realm, service) VALUES (@u, @h, 'customer', @s)
                     ON CONFLICT (username) DO UPDATE SET pass_hash = EXCLUDED.pass_hash,
                       session_epoch = users.session_epoch + 1
                     WHERE users.realm = 'customer' '''),
        parameters: {'u': accountLogin(service, e), 'h': h, 's': service});
    // the epoch cuts the sessions off; deleting them in Redis only cleans up, after the transaction (like Sessions.destroyAll)
    // tokens collected now: a session opened later in the same request is not lost in the cleanup
    try {
      final tokens = await Redis.smembers('csessuser:$service|$e');
      if (tokens.isEmpty) return null;
      await Db.afterTransaction(() async {
        try {
          await Redis.delMany([for (final t in tokens) 'csess:$t']);
          await Redis.cmd(['SREM', 'csessuser:$service|$e', ...tokens]);
        } catch (_) {/* the epoch rejects old sessions anyway */}
      });
    } catch (_) {/* Redis down → the epoch rejects old sessions anyway */}
    return null;
  }

  static const resetTtl = Duration(hours: 1);

  /// Redis key of a reset token — a digest, not the token: a Redis dump gives no links to take over accounts.
  static String resetKey(String token) => 'creset:${sha256.convert(utf8.encode(token))}';

  /// Password fingerprint in the token: after a password change (via another link or by an admin) old links stop working.
  static String passwordFingerprint(String hash) => sha256.convert(utf8.encode('reset|$hash')).toString().substring(0, 16);

  static Future<String?> _accountHash(int service, String email) async {
    final r = await (await Db.connect()).execute(
        Sql.named("SELECT pass_hash FROM users WHERE username=@u AND realm='customer' AND service=@s"),
        parameters: {'u': accountLogin(service, email), 's': service});
    return r.isEmpty ? null : r.first[0] as String? ?? '';
  }

  /// Password reset token for an existing account (also without a password — link/SSO may set one).
  /// null = no account, bad e-mail or limit (3 per 15 min per address, 10/h per IP). The page always shows
  /// the same message — the response does not reveal whether the account exists. The e-mail is sent by the app (its language and sender),
  /// and it MUST NOT wait for it in the request: `await`ing the send only for existing accounts reveals them by response
  /// time. Send in the background (`unawaited`/a queue), respond right away.
  static Future<String?> resetToken(int service, String email, {String ip = ''}) async {
    final e = email.trim().toLowerCase();
    if (!validEmail(e)) return null;
    if (await overLimit('rl:reset:ip:${rateLimitAddress(ip)}', 10, 3600) ||
        await overLimit('rl:reset:${Sessions.hashToken('$service|$e')}', 3, 900)) {
      return null;
    }
    final h = await _accountHash(service, e);
    if (h == null) return null;
    final t = _token();
    await Redis.setEx(resetKey(t), jsonEncode([service, e, passwordFingerprint(h)]), resetTtl.inSeconds);
    return t;
  }

  /// Account e-mail from a valid reset token, or null (bad, used, expired, another service, password already changed).
  static Future<String?> resetEmail(int service, String token) async {
    if (!Sessions.validToken(token)) return null;
    return _resetValueEmail(service, await Redis.get(resetKey(token)));
  }

  static Future<String?> _resetValueEmail(int service, String? value) async {
    final parts = _list(value);
    if (parts == null || parts.length != 3 || parts[0] != service || parts[1] is! String || parts[2] is! String) return null;
    final h = await _accountHash(service, parts[1] as String);
    return h != null && passwordFingerprint(h) == parts[2] ? parts[1] as String : null;
  }

  /// New password from a reset link: '' = set (token used, other account sessions closed), otherwise a message
  /// ([resetMessage] for a bad token, or a password error from [passwordError]).
  static Future<String> resetPassword(int service, String token, String password) async {
    final b = passwordError(password);
    // a mistyped password does not use the link up
    if (b != null) return await resetEmail(service, token) == null ? resetMessage : b;
    if (!Sessions.validToken(token)) return resetMessage;
    // GET+DEL in one script (GETDEL needs Redis 6.2): of parallel resets with this token only one gets the value.
    // Consumed before the database write — a failed write leaves the token used, not reusable. The fingerprint is
    // checked on the consumed value: a password change committed before the consumption still ends the link.
    final taken = await Redis.cmd(['EVAL', "local v = redis.call('GET', KEYS[1]) redis.call('DEL', KEYS[1]) return v",
        '1', resetKey(token)]);
    final e = await _resetValueEmail(service, taken as String?);
    if (e == null) return resetMessage;
    return await setPassword(service, e, password) ?? '';
  }

  static const resetMessage = 'The password reset link is invalid or has expired.';

  /// Messages of [loginWithPassword] — constants, so the front can swap them for a translation.
  static const limitMessage = 'Too many sign-in attempts. Try again in a few minutes.';
  static const passwordMessage = 'Wrong e-mail or password.';

  /// Sign-in with e-mail and password. Returns (session token, '') or (null, message).
  static Future<(String?, String)> loginWithPassword(int service, String email, String password,
      {String ip = ''}) async {
    final e = email.trim().toLowerCase();
    if (!validEmail(e)) return (null, passwordMessage); // garbage does not create keys in Redis
    // address first (30 / 5 min), then the account+address pair (5 / 5 min) — like panel sign-in
    final a = rateLimitAddress(ip);
    if (await overLimit('rl:clogin:ip:$a', 30, 300) ||
        await overLimit('rl:clogin:${Sessions.hashToken('$service|$e|$a')}', 5, 300)) {
      return (null, limitMessage);
    }
    await releaseUnderAttack('rl:caccount:${Sessions.hashToken('$service|$e')}');
    final rows = await (await Db.connect()).execute(
        Sql.named("SELECT pass_hash, session_epoch FROM users WHERE username=@u AND realm='customer' AND service=@s"),
        parameters: {'u': accountLogin(service, e), 's': service});
    final hash = rows.isEmpty ? '' : rows.first[0] as String? ?? '';
    // read together with the hash: a password change committed during bcrypt rejects this session
    final epoch = rows.isEmpty ? 0 : rows.first[1] as int;
    await Db.release(); // bcrypt without holding a pool connection
    if (!await Db.bcrypt(() => passwordMatches(password, hash))) return (null, passwordMessage);
    if (Db.weakHash(hash)) {
      final fresh = await Db.bcrypt(() => Db.hashPassword(password));
      await (await Db.connect()).execute(
          Sql.named("UPDATE users SET pass_hash=@h WHERE username=@u AND realm='customer' AND pass_hash=@s"),
          parameters: {'u': accountLogin(service, e), 'h': fresh, 's': hash});
    }
    try {
      await Redis.delMany(['rl:clogin:${Sessions.hashToken('$service|$e|$a')}', 'rl:caccount:${Sessions.hashToken('$service|$e')}']);
    } catch (_) {}
    return (await _session(service, e, epoch), '');
  }

  /// Account created on first sign-in; every sign-in (password, link, Google/Apple) records its time.
  static const accountSessionSql = '''INSERT INTO users (username, pass_hash, realm, service, last_login)
                   VALUES (@u, '', 'customer', @s, @n)
                   ON CONFLICT (username) DO UPDATE SET last_login = EXCLUDED.last_login''';

  /// Last sign-in of a service's customer accounts: e-mail → epoch ms (no entry = never / no account).
  static Future<Map<String, int>> lastLogins(int service, Iterable<String> emails) async {
    final logins = [for (final e in emails) accountLogin(service, e)];
    if (logins.isEmpty) return const {};
    final rows = await (await Db.connect()).execute(
        Sql.named("SELECT username, last_login FROM users WHERE realm='customer' AND service=@s "
            'AND username = ANY(@u) AND last_login > 0'),
        parameters: {'s': service, 'u': TypedValue(pg.Type.textArray, logins)});
    final p = 'c:$service:';
    return {for (final r in rows) (r[0] as String).substring(p.length): r[1] as int};
  }

  /// E-mails of a service's customer accounts (for the panel list).
  static Future<List<String>> list(int service) async {
    final rows = await (await Db.connect()).execute(
        Sql.named("SELECT username FROM users WHERE realm='customer' AND service=@s ORDER BY username"),
        parameters: {'s': service});
    final p = 'c:$service:';
    return [for (final r in rows) if ((r[0] as String).startsWith(p)) (r[0] as String).substring(p.length)];
  }

  /// Creates the account on first sign-in and opens a session.
  static Future<String> _session(int service, String email, int epoch) async {
    final c = await Db.connect();
    await c.execute(
      Sql.named(accountSessionSql),
      parameters: {'u': accountLogin(service, email), 's': service, 'n': DateTime.now().millisecondsSinceEpoch});
    final t = _token();
    await Redis.setEx('csess:${Sessions.hashToken(t)}', jsonEncode([service, email, epoch]), _ttl);
    await Redis.sadd('csessuser:$service|$email', Sessions.hashToken(t));
    await Redis.expire('csessuser:$service|$email', _ttl); // the set lives as long as the newest session
    return t;
  }

  static Future<CustomerSession?> session(String? token, int service) async {
    if (!Sessions.validToken(token)) return null;
    final parts = _list(await Redis.get('csess:${Sessions.hashToken(token!)}'));
    // a value without the epoch (older format) is not valid — those customers sign in again
    if (parts == null || parts.length != 3 || parts[0] != service || parts[1] is! String || parts[2] is! int) return null;
    final email = parts[1] as String;
    Future<bool> current() async {
      final r = await (await Db.connect()).execute(
          Sql.named("SELECT session_epoch FROM users WHERE username=@u AND realm='customer' AND service=@s"),
          parameters: {'u': accountLogin(service, email), 's': service});
      return r.isNotEmpty && r.first[0] == parts[2];
    }

    final ok = (await Db.connect()).inContext ? await current() : await Db.inContext(service, current);
    return ok ? CustomerSession(email, service) : null;
  }

  /// Redis value as a JSON list — a `|` in the e-mail will not shift fields (SEC-A-16). Any other format = none.
  static List? _list(String? raw) {
    if (raw == null) return null;
    try {
      final v = jsonDecode(raw);
      return v is List ? v : null;
    } on FormatException {
      return null;
    }
  }

  static Future<void> logout(String? token) async {
    if (Sessions.validToken(token)) await Redis.del('csess:${Sessions.hashToken(token!)}');
  }
}
