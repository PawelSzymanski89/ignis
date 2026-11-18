// ============================================================================
//  admin_page.dart — base class of back-office pages
// ----------------------------------------------------------------------------
//  Back office ↔ customer panel split: an account has a REALM
//  (`staff` or `customer`, never both). An admin page checks the realm BEFORE
//  permissions — a second, independent barrier. Even if computing permissions
//  went wrong, a customer account will not enter the back office, because it fails on the realm.
//
//  Pages extending AdminPage do NOT write authorization — they only declare
//  `requires` in @Page. The same `requires` filters the menu (registry.menu).
// ============================================================================

import 'dart:async';

import 'dart:io';

import 'ignis.dart';
import 'db.dart';
import 'i18n.dart';
import 'page_engine.dart';
import 'permissions.dart';
import 'registry.dart';
import 'session.dart';

abstract class AdminPage extends PageEngine {
  Session? _session;
  EffectivePermissions _perms = EffectivePermissions(const [], const []);

  /// Set when the refusal comes from an unchanged initial password — then
  /// we show the password change page instead of sign-in.
  bool _mustChangePassword = false;
  bool get mustChangePassword => _mustChangePassword;


  /// The signed-in user (null before isAbleToSee).
  Session? get session => _session;
  String get login => _session?.username ?? '';

  /// Permissions of the signed-in user — for conditions in actions and in the template.
  EffectivePermissions get permissions => _perms;
  bool can(String key) => _perms.allows(key);

  /// Service of the signed-in account: 0 = platform.
  int _accountService = 0;
  int get accountService => _accountService;


  @override
  Future<bool> isAbleToSee() async {
    // BARRIER 0: the panel lives only under `admin.<domain>`.
    if (!context.panel) return false;

    _session = await Sessions.get(cookie(Sessions.cookieName));
    if (_session == null) return false;

    final account = await Db.account(_session!.username);
    if (account == null) return false;
    // a session from before "sign out everywhere" / a password change — even if Redis did not delete the token
    if (_session!.epoch != account.$4) return false;

    // BARRIER 1: realm. A customer account has no business in the back office.
    if (account.$1 != 'staff') return false;

    // BARRIER 1.5: a password set by someone else. We let in ONLY to
    // the password change page (and sign-out) — a password known to two people
    // must not stay the working password just because it works.
    _mustChangePassword = account.$3;

    // BARRIER 2: the account must belong to the service whose domain we are on.
    // A platform account (0) signs in ONLY under the system domain — it does not enter
    // a customer panel "by the way", even with the right password. Entering
    // someone else's context must be an explicit, recorded act, not a side effect.
    _accountService = account.$2;
    if (_accountService != context.service) return false;

    // BARRIER 3: platform pages are invisible from a service panel — hiding them
    // in the menu is not enough, because the address can be typed by hand.
    if (meta.platformOnly && !context.platform) return false;


    // BARRIER 4: the permission from @Page(requires:)
    _perms = await Permissions.forUser(_session!.username);
    if (_mustChangePassword && !meta.exemptFromPasswordChange) return false;
    return _perms.allows(meta.requires);
  }

  /// Menu label or group in the page language: `ignis.menu.<label_in_snake_case>` from the app or built-in
  /// catalog, otherwise the label as written in `@Page`.
  String menuText(String label) => label.isEmpty
      ? label
      : I18n.find(language.isEmpty ? I18n.languages.first : language,
              'ignis.menu.${label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}') ??
          label;

  /// Model shared by every panel page: menu, who is signed in, flash.
  /// Pages call it at the start of insertData() and add their own put().
  Future<void> sharedData() async {
    put('menu_sections', [
      for (final s in PageRegistry.menuSections(_perms.allows, platform: context.platform))
        {
          'name': menuText(s['name'] as String),
          'items': [
            for (final m in s['items'] as List<Map<String, String>>) {...m, 'label': menuText(m['label']!)}
          ],
        }
    ]);
    put('platform', context.platform);
    put('service_name', context.name);
    put('current', meta.route);
    put('login', login);
    final u = await Permissions.settings(context.service, secrets: false);
    put('settings', u);
    // The browser tab title comes from the label in @Page — one source, no
    // repeating the page name in the template.
    put('page_title', menuText(meta.label ?? ''));
    put('brand', (u['site_name'] ?? '').isEmpty ? Ignis.brand : u['site_name']!);
    // caption under the login in the profile menu: package names, not a made-up "rank"
    put('role', _perms.packages.isEmpty ? t('ignis.nav.no_packages') : _perms.packages.join(', '));
    put('footer', (u['footer'] ?? '').isEmpty ? Ignis.brand : u['footer']!);
    // Which node served this request. With round-robin, without it you cannot
    // tell which node what you see on screen came from — and when
    // diagnosing a divergence between nodes it is the first thing anyone asks.
    put('node', Platform.environment['IGNIS_NODE'] ?? 'unknown');
    // an unsigned, forged or expired message just disappears — no explanation,
    // because the only one who would see it is the forger
    final f = flashFromUrl();
    if (f != null) {
      put('message', f.$2);
      put('message_type', f.$1);
    }
  }

  /// Redirect with a message — the flash travels in the query string, because the session is
  /// shared in Redis between nodes and keeping a one-time
  /// message there would need an extra write on every click.
  /// The message travels in the URL SIGNED with the node key. Without a signature it was enough
  /// to send someone `/admin/services?flash=<any text>` for the panel to show
  /// them a message that looked like a system one — a ready carrier for "Your session
  /// has expired, sign in here".
  bool back(String url, {String? message, String type = 'success'}) {
    redirect(message == null ? url : '$url${url.contains('?') ? '&' : '?'}${flashInUrl(message, type)}');
    return false;
  }

  /// Refusal for an action: no permission for THIS operation (not for the page).
  bool missingPermission(String key) {
    denied = true;
    return back(meta.route, message: t('ignis.permission.missing', {'key': key}), type: 'danger');
  }
}
