// ============================================================================
//  login_page.dart — the "/login" sign-in page (public, handles the form)
// ----------------------------------------------------------------------------
//  Shows the full flow of gates:
//    - GET  → just render the form (insertData).
//    - POST → in processData check the login against the database:
//        * success → create a session, set the cookie, redirect('/dashboard'),
//                    return FALSE (I handled the response, render skipped),
//        * failure → put a message and let the form render with the error.
//  The page is public → isAbleToSee stays true by default.
// ============================================================================

import '../engine/annotations.dart';
import '../engine/ignis.dart';
import '../engine/db.dart';
import '../engine/audit_log.dart';
import '../engine/client_ip.dart';
import '../engine/customer_accounts.dart';
import '../engine/redis.dart';
import '../engine/page_engine.dart';
import '../engine/permissions.dart';
import '../engine/registry.dart';
import '../engine/session.dart';
import '../engine/totp.dart';

@Page('/admin/login', template: 'login.html')
class LoginPage extends PageEngine {
  /// After authorization (public here) — handling the form POST.
  @override
  Future<bool> processData() async {
    if (method != 'POST') return true; // GET → renderuj formularz

    // Second step: the password is already checked, we wait for the code from the app.
    final step2 = (get('step2') ?? '').trim();
    if (step2.isNotEmpty) return _secondFactor(step2);

    final user = get('username') ?? '';
    final pass = get('password') ?? '';

    // Limits (SEC-A-9): a login outside the format does not touch Redis; the address first (30 / 5 min),
    // then the login+address pair (5 / 5 min) under a digest — a foreign address will not lock someone else's account.
    // Fail-closed: without Redis there is no session anyway, and a disabled limit would be a password oracle.
    if (user.isEmpty || user.length > maxLogin) {
      put('error', t('ignis.msg.login.bad_credentials'));
      return true;
    }
    final ip = get('__ip') ?? '';
    final fromUrl = await CustomerAccounts.attempts('rl:ip:${Sessions.hashToken(rateLimitAddress(ip))}', 300);
    final fromAccount = fromUrl > 30 ? 0 : await CustomerAccounts.attempts(Permissions.attemptsKey(user, ip), 300);
    if (fromUrl > 30 || fromAccount > 5) {
      // one entry per lock window — further POSTs over the limit do not flood the audit log
      if (fromUrl == 31 || fromAccount == 6) await _trace(await _author(user), 'login_locked', 'denied');
      put('error', t('ignis.msg.login.too_many'));
      put('username', user);
      return true;
    }

    await CustomerAccounts.releaseUnderAttack('rl:account:${Sessions.hashToken(user)}');
    final ok = await Db.checkLogin(user, pass);

    // The account must belong to the service whose domain it signs in on. Without this
    // a platform account would sign in to any customer's panel with just a password.
    if (ok != null && await Db.accountService(ok) != context.service) {
      await _trace(await _author(user), 'login', 'denied', detail: 'account of another service');
      put('error', t('ignis.msg.login.bad_credentials')); // same message — does not reveal that the account exists
      put('username', user);
      return true;
    }

    if (ok != null) {
      // Success: session + cookie, redirect to the dashboard, NO render.
      // The attempt counter is reset only after a FULL sign-in: with 2FA every step 1
      // with a stolen password would give a fresh counter and a new half-token (SEC-A-7).
      // Where to after sign-in: the FIRST section this account is allowed to see.
      // A hard-coded /admin sent the account to a dashboard it may not
      // open — the panel sent it back to sign-in, and an account with a narrower
      // package could not get anywhere, even though its permissions were correct.
      final perms = await Permissions.forUser(ok);
      final available = PageRegistry.menu(perms.allows, platform: context.platform);

      if (available.isEmpty) {
        // An account without access to anything — we say so plainly instead of
        // bouncing it off the sign-in page in circles.
        put('error', t('ignis.msg.login.no_access'));
        put('username', user);
        return true;
      }

      // Second factor: the password was enough to know WHO, but not to let them in.
      if (await Permissions.hasTotp(ok)) {
        put('step2', await Sessions.halfSession(ok));
        put('login_2fa', ok);
        return true;
      }

      try { await Redis.delMany([Permissions.attemptsKey(user, ip), 'rl:account:${Sessions.hashToken(user)}']); } catch (_) {}
      final token = await Sessions.create(ok);
      await _trace(ok, 'login', 'ok');
      setCookie(Sessions.cookieName, token, maxAge: 60 * 60 * 8); // 8h
      redirect(available.first['route']!);
      return false; // short-circuit — I handled the response
    }

    // Failure: remember the message and the user, and let the form render.
    await _trace(await _author(user), 'login', 'denied');
    put('error', t('ignis.msg.login.bad_credentials'));
    put('username', user);
    return true;
  }


  /// The longest login we check at all (accounts have 3–32 characters).
  static const maxLogin = 64;

  /// How many wrong codes per account per hour before the second factor locks.
  static const maxAccountFailures = 10;

  /// Verifying the code from the app. The session is created ONLY here.
  Future<bool> _secondFactor(String token) async {
    final user = await Sessions.awaitingCode(token);
    if (user == null) {
      put('error', t('ignis.msg.login.expired'));
      return true;
    }
    // A code has six digits and thirty seconds of life, so without an attempt limit
    // guessing is realistic: 5 shots per token and that's it.
    if (await CustomerAccounts.overLimit('2fa-attempt:${Sessions.hashToken(token)}', 5, 300)) {
      await Sessions.endAwaiting(token);
      put('error', t('ignis.msg.login.too_many_codes'));
      return true;
    }

    // Limit per ACCOUNT, across tokens: a new half-token gives no new attempts (SEC-A-7). We count BEFORE
    // checking the code (atomic INCR) — parallel shots do not slip in before the counter.
    final errorsKey = '2fa-fail:$user';
    int attempt;
    try {
      attempt = await Redis.counter(errorsKey, 3600);
    } catch (_) {
      attempt = maxAccountFailures + 2; // fail-closed like the password
    }
    if (attempt > maxAccountFailures) {
      await Sessions.endAwaiting(token);
      if (attempt == maxAccountFailures + 1) {
        await AuditLog.save(
            service: context.service, actor: user, location: '/admin/login', action: '2fa_locked',
            detail: '$maxAccountFailures wrong codes within an hour — second factor locked for an hour',
            ip: remoteAddress, result: 'denied');
      }
      await _trace(user, 'login_2fa_locked', 'denied');
      put('error', t('ignis.msg.login.account_locked'));
      return true;
    }

    final secret = await Permissions.totpSecret(user);
    final counter = secret.isEmpty ? null : Totp.codeCounter(secret, get('code') ?? '');
    // replay: a code accepted once does not pass a second time within the ±1 step window — compare and store
    // in one script, so two parallel submissions of the same code do not both pass
    if (counter == null || !await _consumeCounter(user, counter)) {
      await _trace(user, 'login_2fa', 'denied');
      put('error', t('ignis.msg.login.wrong_code'));
      put('step2', token);
      put('login_2fa', user);
      return true;
    }
    try {
      await Redis.delMany(
          [errorsKey, Permissions.attemptsKey(user, get('__ip') ?? ''), 'rl:account:${Sessions.hashToken(user)}']);
    } catch (_) {}
    await Sessions.endAwaiting(token);
    final perms = await Permissions.forUser(user);
    final available = PageRegistry.menu(perms.allows, platform: context.platform);
    final session = await Sessions.create(user);
    await _trace(user, 'login_2fa', 'ok');
    setCookie(Sessions.cookieName, session, maxAge: 60 * 60 * 8);
    redirect(available.isEmpty ? '/admin' : available.first['route']!);
    return false;
  }

  /// `actor` of a failed sign-in: the login only of an existing back-office account visible in this service, otherwise
  /// [AuditLog.unknown]. The typed text does not go to the audit log — it may be a password typed into the wrong field, and a foreign
  /// login would sign the entry with someone else's name.
  Future<String> _author(String user) async {
    if (!_loginFormat.hasMatch(user)) return AuditLog.unknown;
    return (await Db.account(user))?.$1 == 'staff' ? user : AuditLog.unknown;
  }

  static final _loginFormat = RegExp(r'^[a-zA-Z0-9._-]{3,32}$');

  /// Atomically: accepts [counter] only if it is greater than the last accepted one. The key lives longer than
  /// the acceptance window (±1 step). A Redis error = refusal.
  static Future<bool> _consumeCounter(String user, int counter) async {
    try {
      return await Redis.cmd([
            'EVAL',
            "local o = tonumber(redis.call('GET', KEYS[1]) or '-1') "
                "if tonumber(ARGV[1]) <= o then return 0 end "
                "redis.call('SET', KEYS[1], ARGV[1], 'EX', ARGV[2]) return 1",
            '1',
            '2fa-last:$user',
            '$counter',
            '${3 * Totp.stepSeconds}',
          ]) ==
          1;
    } catch (_) {
      return false;
    }
  }

  /// Sign-in event in the audit log — LoginPage is not an AdminPage, so the engine will not record it.
  Future<void> _trace(String actor, String action, String result, {String detail = ''}) => AuditLog.save(
      service: context.service, actor: actor, location: meta.route, action: action,
      detail: detail, ip: get('__ip') ?? '', result: result);

  /// Template defaults (for a GET and for a POST with an error).
  @override
  void insertData() {
    put('brand', Ignis.brand);
    put('page_title', t('ignis.login.submit'));
    // message after a password change or closed session — only with our signature,
    // so a foreign link cannot show its own text on the sign-in screen
    final f = flashFromUrl();
    if (f != null) put('info', f.$2);
  }
}
