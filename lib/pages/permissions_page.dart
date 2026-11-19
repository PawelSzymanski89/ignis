// ============================================================================
//  permissions_page.dart — "/permissions" (Permissions section)
// ----------------------------------------------------------------------------
//  Three tabs on one page: Packages · Permission catalog · Users.
//  Entry = `permissions.view`. Changing packages = `permissions.edit`,
//  changing accounts = `users.edit` — checked in EVERY action separately, because
//  entering the page is not consent to everything that can be clicked on it.
//
//  Safeguards (each comes from a real way of locking yourself out of the panel):
//   • `root`/`root-u<N>` packages cannot be changed or removed from the panel,
//   • a package is changed/removed only by someone who covers its contents and every holder,
//   • you cannot take `permissions.edit` away from YOURSELF via a package — nobody could undo it,
//   • nobody changes their own packages, grants and denies,
//   • you cannot delete your own account or the last account with `permissions.edit`.
// ============================================================================

import '../engine/admin_page.dart';
import '../engine/annotations.dart';
import '../engine/db.dart';
import '../engine/customer_accounts.dart';
import '../engine/i18n.dart';
import '../engine/list.dart';
import '../engine/permissions.dart';
import '../engine/session.dart';

@Page('/admin/permissions',
    template: 'permissions.html',
    requires: 'permissions.view',
    label: 'Permissions',
    icon: 'fe fe-shield',
    order: 70,
    group: 'System')
class PermissionsPage extends AdminPage {
  /// The platform sees and changes accounts of all services; a customer only its own.
  /// This one getter decides the scope of every account operation below.
  bool get _all => context.platform;
  /// Turns a name into a package id: "Content editor" → "content-editor" (Polish letters folded to ASCII).
  String _slug(String s) {
    const accented = 'ąćęłńóśźż', plain = 'acelnoszz'; // Polish letters in package names
    var t = s.toLowerCase();
    for (var i = 0; i < accented.length; i++) {
      t = t.replaceAll(accented[i], plain[i]);
    }
    t = t.replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    // `root*` and the `-u<N>` suffix belong to system packages and service copies
    if (t.startsWith('root')) t = 'p-$t';
    if (RegExp(r'-u\d+$').hasMatch(t)) t = '$t-p';
    return t.isEmpty ? 'package' : t;
  }

  /// `perm_<key>` checkboxes + a text field with patterns → one list.
  List<String> _collectedPermissions(String patternField) => [
        ...paramsStartingWith('perm_'),
        ...(get(patternField) ?? '')
            .split(RegExp(r'[\s,]+'))
            .where((s) => s.isNotEmpty),
      ].toSet().toList()
        ..sort();

  // ─────────────── packages ───────────────

  @Action('package_add')
  Future<bool> packageAdd() async {
    if (!can('permissions.edit')) return missingPermission('permissions.edit');
    final name = (get('name') ?? '').trim();
    if (name.isEmpty) {
      return back('/admin/permissions', message: t('ignis.msg.permissions.package_name_empty'), type: 'danger');
    }
    // ids are global: taken (also by an invisible package of another service) → next suffix
    var id = _slug(name);
    for (var n = 2; !await Permissions.addPackage(id, name, (get('description') ?? '').trim(), context.service); n++) {
      if (n > 50) return back('/admin/permissions', message: t('ignis.msg.permissions.package_name_taken'), type: 'danger');
      id = '${_slug(name)}-$n';
    }
    return back('/admin/permissions', message: t('ignis.msg.permissions.package_created', {'name': name}));
  }

  @Action('package_save')
  Future<bool> packageSave() async {
    if (!can('permissions.edit')) return missingPermission('permissions.edit');
    final id = get('id') ?? '';
    final package = _packages.where((p) => p.id == id).firstOrNull;
    if (package == null) {
      return back('/admin/permissions', message: t('ignis.msg.permissions.no_package'), type: 'danger');
    }
    final denied = await _notAPackage(package);
    if (denied != null) return back('/admin/permissions', message: denied, type: 'danger');
    final perms = _collectedPermissions('wzorce');
    // As in user_save: you cannot put more into a package than you have yourself — otherwise
    // an "Editor" with permissions.edit added "*" to it and became the service root.
    if (!perms.every(permissions.allows)) {
      return back('/admin/permissions',
          message: t('ignis.msg.permissions.only_own'), type: 'danger');
    }

    // We do not let you cut the ground from under your own feet via a package you have — `root` included.
    if ((await Permissions.userPackages(login)).contains(id) &&
        !await _keepsKey(packageIdValue: id, newPermissions: perms)) {
      return back('/admin/permissions',
          message: t('ignis.msg.permissions.would_lose_edit'),
          type: 'danger');
    }

    await Permissions.savePackage(
        id, (get('name') ?? package.name).trim(), (get('description') ?? package.description).trim(), perms,
        context.service, all: _all);
    return back('/admin/permissions', message: t('ignis.msg.permissions.package_saved', {'name': package.name}));
  }

  @Action('package_delete')
  Future<bool> packageDelete() async {
    if (!can('permissions.edit')) return missingPermission('permissions.edit');
    final id = get('id') ?? '';
    final package = _packages.where((p) => p.id == id).firstOrNull;
    if (package == null) {
      return back('/admin/permissions', message: t('ignis.msg.permissions.no_package'), type: 'danger');
    }
    final denied = await _notAPackage(package);
    if (denied != null) return back('/admin/permissions', message: denied, type: 'danger');
    if ((await Permissions.userPackages(login)).contains(id) &&
        !await _keepsKey(packageIdValue: id, newPermissions: const [])) {
      return back('/admin/permissions',
          message: t('ignis.msg.permissions.delete_would_lose_edit'),
          type: 'danger');
    }
    await Permissions.deletePackage(id, context.service, all: _all);
    return back('/admin/permissions', message: t('ignis.msg.permissions.package_deleted'));
  }

  // ─────────────── users ───────────────

  @Action('user_add')
  Future<bool> userAdd() async {
    if (!can('users.edit')) return missingPermission('users.edit');
    final u = (get('login') ?? '').trim();
    final h = get('password') ?? '';
    if (!RegExp(r'^[a-zA-Z0-9._-]{3,32}$').hasMatch(u)) {
      return back('/admin/permissions',
          message: t('ignis.msg.permissions.login_format'), type: 'danger');
    }
    final wrong = Db.passwordErrorKey(h);
    if (wrong != null) return back('/admin/permissions', message: t(wrong), type: 'danger');
    // Logins are global, so "unavailable" says the account exists somewhere on the platform — a limit
    // (20/h per account) and a "denied" entry in the audit log, so login enumeration is slow and visible.
    if (await CustomerAccounts.overLimit('rl:user_add:${Sessions.hashToken(login)}', 20, 3600)) {
      denied = true;
      return back('/admin/permissions', message: t('ignis.msg.permissions.too_many_accounts'), type: 'danger');
    }
    if (!await Permissions.addUser(u, h, context.service)) {
      denied = true;
      return back('/admin/permissions', message: t('ignis.msg.permissions.login_unavailable'), type: 'danger');
    }
    return back('/admin/permissions', message: t('ignis.msg.permissions.account_created', {'login': u}));
  }

  @Action('user_save')
  Future<bool> userSave() async {
    if (!can('users.edit')) return missingPermission('users.edit');
    final u = (get('user_login') ?? '').trim();
    if (await _account(u) == null) {
      return back('/admin/permissions', message: t('ignis.msg.permissions.no_account'), type: 'danger');
    }
    if (!await _canManage(u)) return _aboveMe();
    // Only packages of THIS service (cache from processData) — foreign ids from the form are dropped.
    final packages = paramsStartingWith('pkg_').where(_packageCache.containsKey).toList();
    final plus = _list('plus');
    final minus = _list('minus');

    // You cannot grant more than you have: an account with just "users.edit"
    // would give itself "*" or the root package and become the panel owner.
    final granted = [...plus, for (final p in packages) ...?_packageCache[p]];
    if (!granted.every(permissions.allows)) {
      return back('/admin/permissions',
          message: t('ignis.msg.permissions.only_own'), type: 'danger');
    }

    // Your own packages and denies are changed by someone else — otherwise a denied user would lift their own deny.
    if (u == login) {
      return back('/admin/permissions',
          message: t('ignis.msg.permissions.not_own'),
          type: 'danger');
    }

    await Permissions.saveUser(u, packages, plus, minus, context.service,
        all: _all);
    final h = get('new_password') ?? '';
    if (h.isNotEmpty) {
      final wrong = Db.passwordErrorKey(h);
      if (wrong != null) {
        return back('/admin/permissions', message: t('ignis.msg.permissions.saved_password_not', {'reason': t(wrong)}), type: 'danger');
      }
      await Permissions.changePassword(u, h, context.service, all: _all);
    }
    return back('/admin/permissions',
        message: t(h.isNotEmpty ? 'ignis.msg.permissions.account_saved_password' : 'ignis.msg.permissions.account_saved', {'login': u}));
  }

  /// Lost phone: an administrator removes the second factor from someone else's account.
  /// The audit log entry is created automatically, so the operation is not silent.
  @Action('user_totp_disable')
  Future<bool> userTotpDisable() async {
    if (!can('users.edit')) return missingPermission('users.edit');
    final u = (get('user_login') ?? '').trim();
    // your own factor only in "My account", with a password — otherwise a hijacked session bypasses that requirement
    if (u == login) {
      return back('/admin/permissions',
          message: t('ignis.msg.permissions.own_totp'), type: 'danger');
    }
    if (await _account(u) == null) {
      return back('/admin/permissions', message: t('ignis.msg.permissions.no_account'), type: 'danger');
    }
    if (!await _canManage(u)) return _aboveMe();
    await Permissions.setTotp(u, '');
    return back('/admin/permissions',
        message: t('ignis.msg.permissions.totp_removed', {'login': u}),
        type: 'warning');
  }

  @Action('user_delete')
  Future<bool> userDelete() async {
    if (!can('users.edit')) return missingPermission('users.edit');
    final u = (get('user_login') ?? '').trim();
    if (u == login) {
      return back('/admin/permissions', message: t('ignis.msg.permissions.not_own_delete'), type: 'danger');
    }
    final k = await _account(u);
    if (k == null) {
      return back('/admin/permissions', message: t('ignis.msg.permissions.no_account'), type: 'danger');
    }
    if (!await _canManage(u)) return _aboveMe();
    // the last account of THIS service that can manage permissions — we do not give it up
    final everyone = await Permissions.forMany(await Permissions.users(k.$2));
    final managers =
        everyone.values.where((x) => x.allows('permissions.edit')).length;
    if (managers <= 1 && (everyone[u]?.allows('permissions.edit') ?? false)) {
      return back('/admin/permissions',
          message: t('ignis.msg.permissions.last_editor'),
          type: 'danger');
    }
    await Permissions.deleteUser(u, context.service, all: _all);
    return back('/admin/permissions', message: t('ignis.msg.permissions.account_deleted', {'login': u}));
  }

  // ─────────────── helpers ───────────────

  /// Back-office account within this page's scope (service — its own, platform — any), or null.
  Future<(String, int, bool, int)?> _account(String u) async {
    final k = await Db.account(u);
    return k != null && k.$1 == 'staff' && (_all || k.$2 == context.service) ? k : null;
  }

  /// Service whose packages this request loads. The platform does not read packages of all services at once:
  /// package from `id`/`package` → its service, account from `user_login`/`account` → its service, otherwise `?service=` (0).
  Future<int> _packagesService() async {
    if (!_all) return context.service;
    final package = get('package') ?? get('id');
    if (package != null) return await Permissions.packageService(package) ?? 0;
    final account = get('user_login') ?? get('account');
    if (account != null) return (await Db.account(account.trim()))?.$2 ?? 0;
    return int.tryParse(get('service') ?? '') ?? 0;
  }

  /// Password, 2FA, packages and removal of someone else's account only when the signed-in user has
  /// at least everything that account has — otherwise an account manager could take over the root account.
  Future<bool> _canManage(String u) async => permissions.includesAll(
      await Permissions.forUser(u), [for (final k in await Permissions.catalog()) k.key]);

  /// Reason to refuse changing/removing a package, or null. The CURRENT contents and holders count:
  /// checking only the new contents let `root` be emptied (`[].every` = true).
  Future<String?> _notAPackage(PermissionPackage p) async {
    if (Permissions.systemPackage(p.id)) {
      return t('ignis.msg.permissions.system_package', {'name': p.name});
    }
    final catalog = [for (final k in await Permissions.catalog()) k.key];
    if (!permissions.includesAll(EffectivePermissions(p.permissions, const []), catalog)) {
      return t('ignis.msg.permissions.package_above');
    }
    final holders = await Permissions.forMany(await Permissions.holders(p.id));
    if (!holders.values.every((x) => permissions.includesAll(x, catalog))) {
      return t('ignis.msg.permissions.holders_above');
    }
    return null;
  }

  bool _aboveMe() => back('/admin/permissions',
      message: t('ignis.msg.permissions.account_above'),
      type: 'danger');

  List<String> _list(String field) => (get(field) ?? '')
      .split(RegExp(r'[\s,]+'))
      .where((s) => s.isNotEmpty)
      .toSet()
      .toList();

  /// Whether the signed-in user still has `permissions.edit` after the package contents change.
  Future<bool> _keepsKey(
      {required String packageIdValue, required List<String> newPermissions}) async {
    final mine = await Permissions.userPackages(login);
    final patterns = <String>[];
    for (final id in mine) {
      patterns.addAll(id == packageIdValue ? newPermissions : (_packageCache[id] ?? const []));
    }
    // plus direct grants — `allow` also contains the old contents of the package being changed
    final fromPackages = _fromPackages(mine);
    patterns.addAll(permissions.allow.where((w) => !fromPackages.contains(w)));
    return EffectivePermissions(patterns, permissions.deny).allows('permissions.edit');
  }

  List<PermissionPackage> _packages = const [];
  final Map<String, List<String>> _packageCache = {};

  @override
  Future<bool> processData() async {
    // packages needed by both actions and the view — read once per request
    _packages = await Permissions.packages(await _packagesService());
    for (final p in _packages) {
      _packageCache[p.id] = p.permissions;
    }
    return true;
  }

  /// The page is just headers (accounts are paged); the accordion content — a form with the catalog
  /// and packages — comes from `?package=` / `?account=` only when expanded (htmx).
  @override
  Future<void> insertData() async {
    await sharedData();
    final catalog = await Permissions.catalog();
    put('can_edit', can('permissions.edit'));
    put('can_users', can('users.edit'));
    // the account list and their effective permissions are a "users preview", not part of permissions.view
    final canAccounts = can('users.view');
    put('can_accounts', canAccounts);

    final packageId = get('package');
    if (packageId != null) {
      final p = _packages.where((p) => p.id == packageId).firstOrNull;
      if (p == null) {
        notFound();
        return;
      }
      put('sections', _sections(catalog));
      put('single_package', _package(p, catalog));
      return;
    }

    final account = get('account');
    if (account != null) {
      if (!canAccounts) {
        forbidden();
        return;
      }
      // the same boundary as the list: a back-office account of this service (platform — any)
      if (await _account(account) == null) {
        notFound();
        return;
      }
      put('packages', [for (final p in _packages) {'id': p.id, 'name': p.name}]);
      put('single_account', (await _accounts([account], catalog, full: true)).single);
      return;
    }

    put('packages', [for (final p in _packages) _package(p, catalog)]);
    put('catalog', catalog.map((k) => {'key': k.key, 'description': _describe(k), 'section': k.section}).toList());

    if (!canAccounts) return;
    final l = Listing.fromPage(this, sorting: const {'login': 'username'}, defaults: 'login', ascending: const {'login'});
    final (total, userList) = await Permissions.usersPage(context.service,
        all: _all, pattern: l.pattern, limit: l.onPage, from: l.offset);
    if (l.outOfRange(total)) return;
    put('listing', l.model(total));
    put('accounts_active', get('per_page') != null);
    put('users', await _accounts(userList, catalog));
  }

  Map<String, Object?> _package(PermissionPackage p, List<PermissionInfo> catalog) => {
        'id': p.id,
        'name': p.name,
        'description': p.description,
        'patterns': p.permissions.where((u) => u.contains('*')).join(' '),
        'count': catalog.where((k) => EffectivePermissions(p.permissions, const []).allows(k.key)).length,
        'checked': {for (final k in catalog) k.key: p.permissions.contains(k.key)},
        'system': Permissions.systemPackage(p.id),
        'body': '/admin/permissions?package=${Uri.encodeQueryComponent(p.id)}',
      };

  /// Built-in permissions are described in the page language; app permissions keep their catalog text.
  String _describe(PermissionInfo k) => I18n.find(language, 'ignis.permission.${k.key}') ?? k.description;

  /// Catalog grouped by section — checkboxes in the package form.
  List<Map<String, Object?>> _sections(List<PermissionInfo> catalog) {
    final sections = <String, List<Map<String, String>>>{};
    for (final k in catalog) {
      (sections[k.section] ??= []).add({'key': k.key, 'description': _describe(k)});
    }
    return [for (final e in sections.entries) {'name': e.key, 'items': e.value}];
  }

  /// Account rows: accordion header, and with [full] also form data.
  Future<List<Map<String, Object?>>> _accounts(List<String> logins, List<PermissionInfo> catalog,
      {bool full = false}) async {
    final perms = await Permissions.forMany(logins);
    final pkg = await Permissions.usersPackages(logins);
    final totp = await Permissions.accountsTotp(logins);
    return [
      for (final (i, u) in logins.indexed)
        {
          'login': u,
          // accordion id by number: a login with a dot gave an invalid selector `#account-a.b`
          'no': i,
          'totp': totp[u] ?? false,
          'is_me': u == login,
          'packages_text': pkg[u]!.join(', '),
          'count': catalog.where((k) => perms[u]!.allows(k.key)).length,
          'body': '/admin/permissions?account=${Uri.encodeQueryComponent(u)}',
          if (full) ...{
            'plus': perms[u]!.allow.where((a) => !_fromPackages(pkg[u]!).contains(a)).join(' '),
            'minus': perms[u]!.deny.join(' '),
            'checked': {for (final p in _packages) p.id: pkg[u]!.contains(p.id)},
            'effective': [for (final k in catalog) if (perms[u]!.allows(k.key)) k.key],
          },
        }
    ];
  }

  Set<String> _fromPackages(List<String> ids) =>
      {for (final id in ids) ...?_packageCache[id]};
}
