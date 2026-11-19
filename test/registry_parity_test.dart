// The generated lib/ignis_registry.g.dart against the expected core list (no reflection scan to compare with):
// every core @Entity (table) and @Page (route, auth flags, actions), working closures, template getters and the
// source fingerprint. Adding or renaming a core class means updating the lists below. Bez bazy.
import 'dart:io';

import 'package:ignis/engine/registry_fingerprint.dart';
import 'package:ignis/ignis.dart';
import 'package:ignis/ignis_registry.g.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

const entities = {
  'AuditLogEntry': 'audit_log',
  'Domain': 'domains',
  'FileRecord': 'files',
  'Folder': 'folders',
  'Package': 'packages',
  'PackagePermission': 'package_permissions',
  'Permission': 'permissions',
  'Service': 'services',
  'Setting': 'settings',
  'User': 'users',
  'UserPackage': 'user_packages',
  'UserPermission': 'user_permissions',
};

// route, AdminPage (cookie auth), actions
const pages = {
  'AccountPage': ('/admin/account', true, ['password', 'sessions', 'totp_disable', 'totp_enable', 'totp_start']),
  'AuditLogPage': ('/admin/audit-log', true, <String>[]),
  'DashboardPage': ('/admin', true, <String>[]),
  'FilesPage': ('/admin/files', true, ['file_delete', 'file_save', 'folder_delete', 'new_folder', 'upload']),
  'HealthPage': ('/health', false, <String>[]),
  'LegacyLogout': ('/logout', false, <String>[]),
  'LoginPage': ('/admin/login', false, <String>[]),
  'LogoutPage': ('/admin/logout', false, <String>[]),
  'PermissionsPage': (
    '/admin/permissions',
    true,
    ['package_add', 'package_delete', 'package_save', 'user_add', 'user_delete', 'user_save', 'user_totp_disable']
  ),
  'ServeFilePage': ('/files', false, <String>[]),
  'SettingsPage': ('/admin/settings', true, ['file_delete', 'save']),
};

void main() {
  final gotEntities = {for (final e in ignisRegistry.entities) e.typeName: e.table};
  check('core entities and tables as expected (${entities.length})',
      gotEntities.length == entities.length && entities.entries.every((e) => gotEntities[e.key] == e.value));
  final gotPages = {for (final p in ignisRegistry.pages) p.typeName: p};
  check('core pages as expected (${pages.length})', gotPages.length == pages.length && gotPages.keys.toSet().containsAll(pages.keys));
  for (final MapEntry(key: name, value: (route, admin, actions)) in pages.entries) {
    final p = gotPages[name]!;
    check(
        '$name: $route, adminPage=$admin, actions=$actions',
        p.page.route == route &&
            p.adminPage == admin &&
            p.cookieAuth == admin &&
            (p.actions.keys.toList()..sort()).join(',') == actions.join(','));
  }
  check('every entity is from package:ignis', ignisRegistry.entities.every((e) => e.library.startsWith('package:ignis/')));

  for (final g in ignisRegistry.entities) {
    final fresh = g.ctor();
    check(
        '${g.typeName}: constructor, field getters, defaults on a fresh instance',
        fresh.runtimeType == g.type &&
            g.fields.where((f) => f.defaultValue != null).every((f) => f.get(fresh) == f.defaultValue));
  }
  final user = User();
  final username = ignisRegistry.entities.firstWhere((e) => e.typeName == 'User').fields.first;
  username.set(user, 'ala');
  check('setter/getter closures write and read the field', user.username == 'ala' && username.get(user) == 'ala');
  final routes = {for (final p in ignisRegistry.pages) p.page.route: p};
  check('page constructor builds the right class', routes['/admin/login']!.ctor() is LoginPage);

  print('template getters (attributes):');
  final users = ignisRegistry.attributes[User]!;
  check('User: every entity field is readable by name',
      ignisRegistry.entities.firstWhere((e) => e.type == User).fields.every((f) => users.containsKey(f.name)));
  check('the getter reads the instance', users['username']!(user) == 'ala');
  check('every registry class has getters',
      ignisRegistry.entities.every((e) => ignisRegistry.attributes.containsKey(e.type)) &&
          ignisRegistry.pages.every((p) => ignisRegistry.attributes.containsKey(p.ctor().runtimeType)));

  print('fingerprint:');
  final f = ignisRegistry.fingerprint!;
  check('package ignis, the generated file left out',
      f.package == 'ignis' && !f.sources.contains(generatedRegistryPath) && f.sources.contains('lib/ignis.dart'));
  final root = Directory.current;
  check('the committed registry matches lib/ (else run dart run build_runner build)',
      staleRegistryWarning(f, root: root) == null);
}
