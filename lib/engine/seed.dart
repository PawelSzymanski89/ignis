// ============================================================================
//  seed.dart — initial data (idempotent)
// ----------------------------------------------------------------------------
//  The permission catalog, starter packages and site settings come from CODE,
//  not from a migration file — together with auto-schema (schema.dart) this gives a new node
//  that after `dart run` has all tables and data without manual SQL.
//
//  Every INSERT is ON CONFLICT DO NOTHING, so a restart breaks nothing
//  and does not overwrite changes made in the panel.
// ============================================================================

import 'dart:io';

import 'package:postgres/postgres.dart' show Sql;

import 'ignis.dart';
import 'db.dart';
import 'config.dart';
import 'schema.dart';

class Seed {
  /// Permission catalog — what can be granted at all: core + app permissions.
  static List<(String, String)> get catalog => [..._core, ...Ignis.permissions];

  static const _core = <(String, String)>[
    ('dashboard.view', 'Access to the dashboard'),
    ('settings.view', 'View site settings'),
    ('settings.edit', 'Change site settings'),
    ('permissions.view', 'View packages and permissions'),
    ('permissions.edit', 'Create and change packages'),
    ('users.view', 'View users'),
    ('users.edit', 'Create, edit and delete users'),
    // Files split into separate permissions: one "media.upload" gave the uploader
    // also the right to delete other people's files and whole folders.
    ('audit_log.view', 'View the audit log'),
    ('files.view', 'View the file manager'),
    ('files.upload', 'Upload files'),
    ('files.edit', 'Rename, describe and move files'),
    ('files.delete', 'Delete files'),
    ('files.folders', 'Create and delete folders'),
  ];

  static const _packages = <(String, String, String, List<String>)>[
    ('root', 'Root', 'Full access to everything', ['*']),
    ('viewer', 'Viewer', 'Read-only',
        ['dashboard.view', 'users.view', 'files.view', 'audit_log.view']),
  ];

  // Defaults come from the field descriptions (engine/config.dart) — one source
  // of truth for the panel and for the seed, so a new field needs no change to this file.

  /// Under the start-up lock of `Schema.sync` ([Schema.startLock]) — parallel nodes do not both seed the admin account.
  static Future<void> seed() => Schema.underStartLock(_seed);

  static Future<void> _seed() async {
    final c = await Db.connect();

    for (final (k, o) in catalog) {
      await c.execute(
        Sql.named('INSERT INTO permissions (key, description) VALUES (@k,@o) '
            'ON CONFLICT (key) DO NOTHING'),
        parameters: {'k': k, 'o': o},
      );
    }
    for (final (id, name, description, perms) in _packages) {
      await c.execute(
        Sql.named('INSERT INTO packages (id, name, description) VALUES (@i,@n,@o) '
            'ON CONFLICT (id) DO NOTHING'),
        parameters: {'i': id, 'n': name, 'o': description},
      );
      for (final u in perms) {
        await c.execute(
          Sql.named('INSERT INTO package_permissions (package_id, permission) '
              'VALUES (@i,@p) ON CONFLICT DO NOTHING'),
          parameters: {'i': id, 'p': u},
        );
      }
    }
    // PLATFORM settings (service 0); every new service gets its own copy
    // when it is created
    for (final e in defaultSettings.entries) {
      await c.execute(
        Sql.named('''INSERT INTO settings (id, key, value, service)
                     VALUES (@i, @k, @v, 0) ON CONFLICT (id) DO NOTHING'''),
        parameters: {'i': '${e.key}@0', 'k': e.key, 'v': e.value},
      );
    }

    // Initial account: SOMEONE must be able to enter the panel after the first start.
    // Password from env (IGNIS_ADMIN_PASS) or random — a random one is printed ONCE to the console.
    final hasAdmin = (await c.execute('SELECT count(*) FROM users')).first[0] as int;
    if (hasAdmin == 0) {
      // empty (IGNIS_ADMIN_PASS= from an env file) counts as missing — otherwise the admin account would get an empty password
      final fromEnv = (Platform.environment['IGNIS_ADMIN_PASS'] ?? '').trim();
      final password = fromEnv.isEmpty ? Db.randomPassword() : fromEnv;
      final wrong = Db.passwordError(password);
      if (wrong != null) throw StateError('IGNIS_ADMIN_PASS: $wrong');
      // `must_change_password` = true: this password went through the console and the systemd log,
      // so the panel lets the account in ONLY to the password change page
      await c.execute(
        Sql.named('''INSERT INTO users (username, pass_hash, realm, must_change_password)
                     VALUES (@u, @h, 'staff', true)'''),
        parameters: {'u': 'admin', 'h': Db.hashPassword(password)},
      );
      // a password given by the operator does not go to the logs (journald, container) — they know it anyway
      stdout.writeln(fromEnv.isEmpty
          ? 'Ignis: created account admin / $password  ← save it now, '
              'it will not be shown again. The panel will ask for a change on first sign-in.'
          : 'Ignis: account admin created (password from IGNIS_ADMIN_PASS). '
              'The panel will ask for a change on first sign-in.');
      // Root ONLY for the account created in this run. A blanket "platform account without
      // packages → root" on every start made root of every account created
      // by an account manager or stripped of packages (SEC-A-1).
      await c.execute(
          Sql.named("INSERT INTO user_packages (username, package_id) VALUES (@u, 'root') "
              'ON CONFLICT DO NOTHING'),
          parameters: {'u': 'admin'});
    }
  }
}
