// ============================================================================
//  dashboard_page.dart — "/" root dashboard of the panel
// ----------------------------------------------------------------------------
//  Back-office start page. It extends AdminPage, so it does not write
//  authorization — it only declares requires in @Page, and the realm and permissions are checked
//  by the base class (two barriers). Label+icon = the menu item from the registry.
// ============================================================================

import '../engine/admin_page.dart';
import '../engine/annotations.dart';
import '../engine/permissions.dart';

@Page('/admin',
    template: 'dashboard.html',
    requires: 'dashboard.view',
    label: 'Dashboard',
    icon: 'fe fe-home',
    order: 10)
class DashboardPage extends AdminPage {
  static const _overview = 20;

  @override
  Future<void> insertData() async {
    await sharedData();

    final packages = await Permissions.packages(context.service); // platform — its own (service 0), not everyone's
    final catalog = await Permissions.catalog();
    // the overview is a sample — on the platform, accounts of all services; the full list is in Permissions
    // accounts, their packages and permission counts — only with "users preview", not with dashboard.view alone
    final canAccounts = can('users.view');
    final (total, userList) = await Permissions.usersPage(context.service,
        all: context.platform, limit: canAccounts ? _overview : 0);
    final mine = permissions;

    put('user_count', total);
    put('overview_more', total - userList.length);
    put('package_count', packages.length);
    put('permission_count', catalog.length);
    put('my_count', catalog.where((k) => mine.allows(k.key)).length);

    // expanded permissions of the signed-in user: patterns → specific keys, after denies
    put('my_permissions', [
      for (final k in catalog)
        if (mine.allows(k.key)) {'key': k.key, 'description': k.description}
    ]);
    put('my_patterns', mine.allow);
    put('my_deny', mine.deny);

    // maps, not PermissionPackage objects: `p.name` on an object needs dart:mirrors, which an AOT build lacks
    put('packages', [
      for (final p in packages) {'name': p.name, 'description': p.description, 'permissions': p.permissions}
    ]);
    if (!canAccounts) return;
    // overview: who has which packages
    // two queries for the whole list, not two per account
    final perms = await Permissions.forMany(userList);
    final pkg = await Permissions.usersPackages(userList);
    final map = <Map<String, Object?>>[
      for (final u in userList)
        {
          'login': u,
          'packages': pkg[u]!.join(', '),
          'count': catalog.where((k) => perms[u]!.allows(k.key)).length,
        }
    ];
    put('overview', map);

  }
}
