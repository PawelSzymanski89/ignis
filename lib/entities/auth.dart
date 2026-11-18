// ============================================================================
//  auth.dart — entities for accounts, permissions and settings (ZERO codegen, zero migrations)
// ----------------------------------------------------------------------------
//  The tables are created and grow BY THEMSELVES from these classes — see engine/schema.dart
//  (the equivalent of hibernate.hbm2ddl.auto=update). Adding a field here = adding a
//  columns on the next node startup.
//
//  A field's initial value becomes the column DEFAULT, so adding a field to
//  a table with data leaves no NULLs.
//
//  Permission model: effective = (packages ∪ grants +) \ grants −, deny beats everything.
// ============================================================================

import '../engine/annotations.dart';

/// Account. PK = login. `realm` separates the back office from the customer panel.
@Entity('users', pk: 'username')
class User {
  String? username;
  String pass_hash = '';
  String realm = 'staff'; // 'staff' = back office, 'customer' = customer panel
  /// Service the account belongs to. 0 = PLATFORM (our accounts, they see everything).
  int service = 0;
  /// The password was set by someone else (seed, platform owner, service administrator),
  /// so until it is changed two people know it. The panel lets such an account in ONLY
  /// to the password change page — otherwise a password from an e-mail or the console stays for years.
  bool must_change_password = false;
  /// Second factor (TOTP) secret, encrypted with the node key. Empty = the account
  /// is protected by the password alone. The threat model puts back-office account takeover in
  /// second place, and a platform account sees all customers' data.
  String totp = '';
  /// Panel session generation number: `Sessions.destroyAll` bumps it, and a session with another number
  /// is rejected — revocation does not depend on whether Redis managed to delete the tokens.
  int session_epoch = 0;
  /// Last session opening (epoch ms), 0 = never. Only customer accounts for now (CustomerAccounts).
  int last_login = 0;
}

/// Permission catalog — the dictionary of what can be granted at all.
@Entity('permissions', pk: 'key')
class Permission {
  String? key; // 'section.action'
  String description = '';
}

/// A named bundle of permissions.
/// A named bundle of permissions. It BELONGS TO A SERVICE — otherwise a customer editing its own
/// "Editor" would change it for everyone else. Starter packages are copied to
/// every new service from the platform templates, with id `<code>-u<service>`
/// (e.g. `editor-u7`), so the primary key stays single-column.
@Entity('packages', pk: 'id')
class Package {
  String? id;
  String name = '';
  String description = '';
  int service = 0;
}

/// Package contents. `permission` can be a pattern: 'content.*', '*'.
@Entity('package_permissions', unique: [
  ['package_id', 'permission']
])
class PackagePermission {
  int? id;
  String package_id = '';
  String permission = '';
}

/// Assignment of a package to an account (an account may have several).
@Entity('user_packages', unique: [
  ['username', 'package_id']
])
class UserPackage {
  int? id;
  String username = '';
  String package_id = '';
}

/// Pojedyncze nadpisanie: allow=true → grant `+`, allow=false → deny `−`.
@Entity('user_permissions', unique: [
  ['username', 'permission']
])
class UserPermission {
  int? id;
  String username = '';
  String permission = '';
  bool allow = true;
}

/// Site settings (key→value). They BELONG TO A SERVICE — each has its own values.
/// The primary key is composite (key + service), so `id` has the form `<key>@<service>`.
@Entity('settings', pk: 'id')
class Setting {
  String? id;
  String key = '';
  String value = '';
  int service = 0;
}
