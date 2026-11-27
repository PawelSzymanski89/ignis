// ============================================================================
//  account_page.dart — "/admin/account": own password and sessions
// ----------------------------------------------------------------------------
//  The panel used to have no place where a user changes THEIR OWN password:
//  the only way was asking an administrator, i.e. handing them the password.
//
//  This is also the only page the panel lets in an account whose password was set
//  by someone else (`exemptFromPasswordChange`). A password from the system start, from an e-mail
//  from the owner or from a reset is known to two people — until it is changed,
//  the rest of the panel is closed.
// ============================================================================

import '../engine/admin_page.dart';
import '../engine/ignis.dart';
import '../engine/annotations.dart';
import '../engine/permissions.dart';
import '../engine/redis.dart';
import '../engine/session.dart';
import '../engine/crypto.dart';
import '../engine/totp.dart';

@Page('/admin/account',
    template: 'account.html',
    // `requires: ''` (no permission, on purpose): every panel account changes its own password and 2FA, even
    // without `dashboard.view` — otherwise an account that must change its password could not enter the only
    // allowed page.
    requires: '',
    // NO `label`: the page is deliberately outside the side menu — it is entered
    // from the profile dropdown in the top bar, where everyone looks for it.
    exemptFromPasswordChange: true)
class AccountPage extends AdminPage {
  /// A restricted session runs only the actions that lift the restriction: the password first,
  /// then the second factor. Anything else (sign out everywhere, a made-up name) → back here.
  @override
  Future<bool> beforeAction(String name) async {
    if (!restricted) return true;
    final allowed = mustChangePassword ? const {'password'} : const {'password', 'totp_start', 'totp_enable'};
    if (allowed.contains(name)) return true;
    back('/admin/account',
        message: t(mustChangePassword ? 'ignis.account.must_change' : 'ignis.account.must_enable_totp'),
        type: 'danger');
    return false;
  }

  @Action('password')
  Future<bool> password() async {
    final error = await Permissions.ownPassword(
        login, get('old_password') ?? '', get('new_password') ?? '', get('repeat_password') ?? '', ip: remoteAddress);
    if (error.isNotEmpty) {
      return back('/admin/account', message: t(error), type: 'danger');
    }
    // a password change deletes ALL sessions, this one too — the user signs in with the new one
    return back('/admin/login',
        message: t('ignis.msg.account.password_changed'));
  }

  /// Enabling, step 1: we show the secret. It is saved ONLY after
  /// the user types a correct code from the app — otherwise the first typo
  /// locks the account for good. The pending secret is kept in Redis next to the
  /// session, not in the form: the browser cannot slip in its own (SEC-A-12).
  @Action('totp_start')
  Future<bool> totpStart() async {
    if (await Permissions.hasTotp(login)) return _alreadyEnabled();
    _newSecret = Totp.newSecret();
    // encrypted: a Redis dump during enabling does not reveal a secret that will be live after confirmation
    await Redis.setEx(_pendingKey, Crypto.encrypt(_newSecret, context: _pendingContext), 600);
    return true;
  }

  @Action('totp_enable')
  Future<bool> totpEnable() async {
    // an active factor is not swapped without a password — first "disable" (with the password)
    if (await Permissions.hasTotp(login)) return _alreadyEnabled();
    final secret = Crypto.decrypt(await Redis.get(_pendingKey) ?? '', context: _pendingContext);
    if (secret.isEmpty) {
      return back('/admin/account', message: t('ignis.msg.account.totp_expired'), type: 'danger');
    }
    // a hijacked session does not add its own factor (and lock the owner out with it) without the password
    if (!await Permissions.confirmPassword(login, get('password_confirm') ?? '', remoteAddress)) {
      _newSecret = secret;
      put('code_error', t('ignis.msg.account.wrong_password'));
      return true;
    }
    if (!Totp.matches(secret, get('code') ?? '')) {
      _newSecret = secret;
      put('code_error', t('ignis.msg.account.wrong_code'));
      return true;
    }
    await Permissions.setTotp(login, secret);
    await Redis.del(_pendingKey);
    // sessions opened with the password alone (including possibly hijacked ones) end; this one gets a new token
    await Sessions.destroyAll(login);
    setCookie(Sessions.cookieName, await Sessions.create(login), maxAge: Sessions.ttlSeconds);
    return back('/admin/account',
        message: t('ignis.msg.account.totp_enabled'));
  }

  String get _pendingContext => 'totp-nowy|$login';

  String get _pendingKey => 'totp-new:${Sessions.hashToken(cookie(Sessions.cookieName) ?? '')}';

  bool _alreadyEnabled() => back('/admin/account',
      message: t('ignis.msg.account.totp_already'),
      type: 'danger');

  /// Disabling requires the password: being signed in is not enough, because the second factor
  /// is meant to protect exactly against someone who took over an open session.
  @Action('totp_disable')
  Future<bool> totpDisable() async {
    // a required factor is not removed by the account itself — the restriction would come straight back;
    // only another administrator (permissions panel) or `bin/account.dart disable-2fa` clears it
    if (AdminPage.totpRequired(accountService)) {
      return back('/admin/account', message: t('ignis.msg.account.totp_required'), type: 'danger');
    }
    if (!await Permissions.confirmPassword(login, get('password_confirm') ?? '', remoteAddress)) {
      return back('/admin/account', message: t('ignis.msg.account.wrong_password'), type: 'danger');
    }
    await Permissions.setTotp(login, '');
    return back('/admin/account',
        message: t('ignis.msg.account.totp_disabled'),
        type: 'warning');
  }

  String _newSecret = '';

  /// Sign out of other devices without changing the password.
  @Action('sessions')
  Future<bool> sessions() async {
    await Sessions.destroyAll(login);
    return back('/admin/login',
        message: t('ignis.msg.account.sessions_closed'));
  }

  @override
  Future<void> insertData() async {
    await sharedData();
    put('must_change', mustChangePassword);
    put('must_enable_totp', mustEnableTotp && !mustChangePassword);
    put('totp_required', AdminPage.totpRequired(accountService));
    put('has_totp', await Permissions.hasTotp(login));
    put('new_secret', _newSecret);
    put('new_secret_readable', _newSecret.isEmpty ? '' : Totp.readable(_newSecret));
    put('new_secret_uri',
        _newSecret.isEmpty ? '' : Totp.address(_newSecret, login, context.platform ? Ignis.brand : context.name));
    // a platform account sees all customers' data — there, missing 2FA is no small matter
    put('recommended', context.platform);
    put('my_login', login);
    put('my_service', context.platform ? 'platform' : context.name);
    put('packages', permissions.packages);
    put('session_hours', Sessions.ttlSeconds ~/ 3600);
  }
}
