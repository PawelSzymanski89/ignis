// ============================================================================
//  permissions.dart — permission packages
// ----------------------------------------------------------------------------
//  Permission = a `section.action` string (content.edit, users.view).
//  Package    = a named bundle of permissions, assigned to a user (who may have several).
//  Grants     = single per-user overrides: `+` adds, `−` takes away.
//
//  EFFECTIVE = (union of packages ∪ grants +) \ grants −
//  DENY BEATS EVERYTHING — one `−` takes a permission away no matter how many
//  packages give it. Otherwise "I revoked someone's access" would mean one thing today
//  and another tomorrow (after adding another package), and the result would depend on order.
//
//  Patterns: `content.*` (whole section) and `*` (everything) — they work on both sides,
//  in denies too (`content.*` among the minuses takes the whole section away).
//
//  User permissions are cached in Redis (`perm:<user>`), so
//  the check in isAbleToSee does not hit the database per request. Every change of a package
//  or grant calls invalidate() — otherwise revoking access would take effect with a delay.
// ============================================================================

import 'dart:convert';

import 'package:postgres/postgres.dart';

import 'db.dart';
import 'client_ip.dart';
import 'redis.dart';
import 'session.dart';
import 'crypto.dart';
import 'totp.dart';

/// Permission package (a `packages` row + its `package_permissions`).
class PermissionPackage {
  PermissionPackage(this.id, this.name, this.description, this.permissions);
  final String id;
  final String name;
  final String description;
  final List<String> permissions; // keys or patterns
}

/// Permission from the catalog (`permissions`).
class PermissionInfo {
  PermissionInfo(this.key, this.description);
  final String key;
  final String description;
  String get section => key.split('.').first;
}

/// Effective permissions of a user — sets of patterns, not expanded keys.
class EffectivePermissions {
  EffectivePermissions(this.allow, this.deny, [this.packages = const []]);
  final List<String> allow;
  final List<String> deny;

  /// Package names of the account (caption in the profile menu) — in the same cache as the permissions (PERF-A-2).
  final List<String> packages;

  /// Whether a pattern covers a specific key. `*` = everything, `section.*` = the whole section.
  static bool covers(String pattern, String key) {
    if (pattern == '*' || pattern == key) return true;
    if (pattern.endsWith('.*')) {
      return key.startsWith('${pattern.substring(0, pattern.length - 2)}.');
    }
    return false;
  }

  /// DENY first — only then we look for a grant. [isRequired] can be a pattern (granting
  /// `x.*`): a deny on `x.y` inside it refuses too, otherwise `*` with a deny would pass on `x.*`.
  bool allows(String? isRequired) {
    if (isRequired == null || isRequired.isEmpty) return true;
    if (deny.any((w) => covers(w, isRequired) || covers(isRequired, w))) return false;
    return allow.any((w) => covers(w, isRequired));
  }

  /// Whether these permissions cover EVERYTHING [other] can do: every key of the [catalog] and every
  /// pattern granted to [other] (keys outside the catalog, e.g. future ones). Managing an account
  /// (password, 2FA, packages, removal) is allowed only to someone who has at least as much.
  bool includesAll(EffectivePermissions other, Iterable<String> catalog) =>
      catalog.every((k) => !other.allows(k) || allows(k)) &&
      other.allow.every((w) => allow.any((a) => covers(a, w))) &&
      deny.every((d) =>
          other.deny.any((x) => covers(x, d)) || !other.allow.any((w) => covers(w, d) || covers(d, w)));

  Map<String, Object?> toJson() => {'a': allow, 'd': deny, 'p': packages};
  static EffectivePermissions fromJson(Map j) => EffectivePermissions(
      List<String>.from(j['a'] ?? []), List<String>.from(j['d'] ?? []), List<String>.from(j['p'] ?? []));
}

class Permissions {
  static const _ttlCache = 900; // 15 min — we invalidate explicitly on change anyway

  // ── reading a user's permissions (from the cache) ──

  static Future<EffectivePermissions> forUser(String username) async {
    try {
      final raw = await Redis.get('perm:$username');
      final j = raw == null ? null : jsonDecode(raw) as Map;
      if (j != null && j.containsKey('p')) return EffectivePermissions.fromJson(j); // an entry from before 'p' — recompute
    } catch (_) {/* Redis down → compute from the database, just slower */}

    final u = await _fromDb(username);
    try {
      await Redis.setEx('perm:$username', jsonEncode(u.toJson()), _ttlCache);
    } catch (_) {}
    return u;
  }

  /// Drops the permission cache — CALL after every change of a package/grant/assignment.
  /// Without [username] — for all back-office accounts (e.g. after a catalog change).
  static Future<void> invalidate([String? username]) async =>
      invalidateMany(username != null ? [username] : await users(0, all: true));

  /// Drops the permission cache of [logins] (e.g. holders of a changed package). After the request transaction ends;
  /// without an open transaction right away — then a Redis error goes to the caller instead of quietly leaving
  /// old permissions in the cache for [_ttlCache].
  static Future<void> invalidateMany(List<String> logins) =>
      Db.afterTransaction(() => Redis.delMany([for (final u in logins) 'perm:$u']));

  /// Permissions of MANY accounts in two queries — the dashboard and the user list
  /// used to make 2-3 queries per account.
  static Future<Map<String, EffectivePermissions>> forMany(List<String> logins) async {
    if (logins.isEmpty) return const {};
    final c = await Db.connect();
    final list = TypedValue(Type.textArray, logins);
    final fromPackages = await c.execute(
      Sql.named('''SELECT up.username, pp.permission FROM user_packages up
                   JOIN package_permissions pp ON pp.package_id = up.package_id
                   WHERE up.username = ANY(@u)'''),
      parameters: {'u': list},
    );
    final grants = await c.execute(
      Sql.named('SELECT username, permission, allow FROM user_permissions WHERE username = ANY(@u)'),
      parameters: {'u': list},
    );
    final allow = <String, List<String>>{}, deny = <String, List<String>>{};
    for (final r in fromPackages) {
      (allow[r[0] as String] ??= []).add(r[1] as String);
    }
    for (final r in grants) {
      ((r[2] == true ? allow : deny)[r[0] as String] ??= []).add(r[1] as String);
    }
    return {
      for (final u in logins) u: EffectivePermissions(allow[u] ?? const [], deny[u] ?? const []),
    };
  }

  /// Pakiety WIELU kont jednym zapytaniem.
  static Future<Map<String, List<String>>> usersPackages(List<String> logins) async {
    if (logins.isEmpty) return const {};
    final r = await (await Db.connect()).execute(
      Sql.named('SELECT username, package_id FROM user_packages WHERE username = ANY(@u)'),
      parameters: {'u': TypedValue(Type.textArray, logins)},
    );
    final out = {for (final u in logins) u: <String>[]};
    for (final x in r) {
      out[x[0] as String]?.add(x[1] as String);
    }
    return out;
  }

  static Future<EffectivePermissions> _fromDb(String username) async {
    final c = await Db.connect();
    final fromPackages = await c.execute(
      Sql.named('''SELECT pp.permission FROM user_packages up
                   JOIN package_permissions pp ON pp.package_id = up.package_id
                   WHERE up.username = @u'''),
      parameters: {'u': username},
    );
    final grants = await c.execute(
      Sql.named('SELECT permission, allow FROM user_permissions WHERE username = @u'),
      parameters: {'u': username},
    );
    final names = await c.execute(
      Sql.named('''SELECT p.name FROM user_packages up JOIN packages p ON p.id = up.package_id
                   WHERE up.username = @u ORDER BY p.name'''),
      parameters: {'u': username},
    );
    return EffectivePermissions(
      [
        ...fromPackages.map((r) => r[0] as String),
        ...grants.where((r) => r[1] == true).map((r) => r[0] as String),
      ],
      grants.where((r) => r[1] == false).map((r) => r[0] as String).toList(),
      [for (final r in names) r[0] as String],
    );
  }

  // ── permission catalog ──

  static Future<List<PermissionInfo>> catalog() async {
    final r = await (await Db.connect())
        .execute('SELECT key, description FROM permissions ORDER BY key');
    return r.map((x) => PermissionInfo(x[0] as String, (x[1] ?? '') as String)).toList();
  }

  // ── packages ──

  /// Packages of ONE service. Same as with accounts: without the filter a customer saw
  /// platform packages and could save or delete them — and they hang on our accounts.
  static Future<List<PermissionPackage>> packages(int service, {bool all = false}) async {
    final c = await Db.connect();
    final p = all
        ? await c.execute('SELECT id, name, description FROM packages ORDER BY name')
        : await c.execute(
            Sql.named('SELECT id, name, description FROM packages WHERE service=@u ORDER BY name'),
            parameters: {'u': service});
    // only permissions of the listed packages — not the whole table filtered in Dart
    final pp = all
        ? await c.execute('SELECT package_id, permission FROM package_permissions')
        : await c.execute(
            Sql.named('''SELECT package_id, permission FROM package_permissions
                         WHERE package_id IN (SELECT id FROM packages WHERE service=@u)'''),
            parameters: {'u': service});
    final contents = <String, List<String>>{};
    for (final x in pp) {
      (contents[x[0] as String] ??= []).add(x[1] as String);
    }
    return [
      for (final r in p)
        PermissionPackage(r[0] as String, r[1] as String, (r[2] ?? '') as String,
            (contents[r[0]] ?? <String>[])..sort())
    ];
  }

  /// `root` and its service copies `root-u<N>` — the last guarantee of access: the panel neither changes nor removes them.
  static bool systemPackage(String id) => id == 'root' || RegExp(r'^root-u\d+$').hasMatch(id);

  /// Accounts that have the package.
  static Future<List<String>> holders(String id) async => [
        for (final r in await (await Db.connect()).execute(
            Sql.named('SELECT username FROM user_packages WHERE package_id=@i'), parameters: {'i': id}))
          r[0] as String
      ];

  /// False = id taken (also by a package of another service, invisible through RLS).
  static Future<bool> addPackage(
      String id, String name, String description, int service) async {
    final r = await (await Db.connect()).execute(
      Sql.named('''INSERT INTO packages (id, name, description, service) VALUES (@i, @n, @o, @u)
                   ON CONFLICT DO NOTHING'''),
      parameters: {'i': id, 'n': name, 'o': description, 'u': service},
    );
    return r.affectedRows == 1;
  }

  /// Service of the package, or null when it does not exist.
  static Future<int?> packageService(String id) async {
    final r = await (await Db.connect())
        .execute(Sql.named('SELECT service FROM packages WHERE id=@i'), parameters: {'i': id});
    return r.isEmpty ? null : r.first[0] as int;
  }

  /// Whether the package belongs to this service.
  static Future<bool> ownPackage(String id, int service) async {
    final r = await (await Db.connect()).execute(
      Sql.named('SELECT count(*)::int FROM packages WHERE id=@i AND service=@u'),
      parameters: {'i': id, 'u': service});
    return (r.first[0] as int) > 0;
  }

  static Future<void> savePackage(String id, String name, String description,
      List<String> permissions, int service, {bool all = false}) async {
    if (!all && !await ownPackage(id, service)) return;
    // in a transaction: a failure halfway does not leave the package without permissions (PERF-A-3)
    await (await Db.connect()).runTx((c) async {
      await c.execute(
        Sql.named('UPDATE packages SET name=@n, description=@o WHERE id=@i'),
        parameters: {'i': id, 'n': name, 'o': description},
      );
      await c.execute(Sql.named('DELETE FROM package_permissions WHERE package_id=@i'),
          parameters: {'i': id});
      for (final u in permissions.toSet()) {
        await c.execute(
          Sql.named('INSERT INTO package_permissions (package_id, permission) VALUES (@i, @p)'),
          parameters: {'i': id, 'p': u},
        );
      }
    });
    await invalidateMany(await holders(id)); // the package hangs on many accounts — clear them all
  }

  static Future<void> deletePackage(String id, int service,
      {bool all = false}) async {
    if (!all && !await ownPackage(id, service)) return;
    final had = await holders(id);
    await (await Db.connect()).runTx((c) async {
      await c.execute(Sql.named('DELETE FROM package_permissions WHERE package_id=@i'),
          parameters: {'i': id});
      await c.execute(Sql.named('DELETE FROM user_packages WHERE package_id=@i'),
          parameters: {'i': id});
      await c.execute(Sql.named('DELETE FROM packages WHERE id=@i'), parameters: {'i': id});
    });
    await invalidateMany(had);
  }

  // ── users ──

  /// Accounts of ONE service. The parameter is required — without it a customer saw
  /// platform accounts and other customers' accounts, and having "users.edit" could
  /// change their passwords. The platform (service 0) passes `all: true`.
  static Future<List<String>> users(int service, {bool all = false}) async {
    final c = await Db.connect();
    // back office only — customer accounts (realm customer) are not staff
    final r = all
        ? await c.execute("SELECT username FROM users WHERE realm='staff' ORDER BY username")
        : await c.execute(
            Sql.named("SELECT username FROM users WHERE service=@u AND realm='staff' ORDER BY username"),
            parameters: {'u': service});
    return r.map((x) => x[0] as String).toList();
  }

  /// Page of accounts for the panel list: count of matches and [limit] logins from [from] (by login).
  /// [pattern] is a ready ILIKE pattern (e.g. `Listing.pattern`). Scope as in [users].
  static Future<(int, List<String>)> usersPage(int service,
      {bool all = false, String pattern = '%', int limit = 50, int from = 0}) async {
    final c = await Db.connect();
    final location = "realm='staff' AND username ILIKE @q${all ? '' : ' AND service=@u'}";
    final pairs = {'q': pattern, if (!all) 'u': service};
    final count = await c.execute(Sql.named('SELECT count(*)::int FROM users WHERE $location'), parameters: pairs);
    final r = await c.execute(
        Sql.named('SELECT username FROM users WHERE $location ORDER BY username LIMIT @l OFFSET @o'),
        parameters: {...pairs, 'l': limit, 'o': from});
    return (count.first[0] as int, [for (final x in r) x[0] as String]);
  }

  /// Whether the account belongs to this service. Every change of someone else's account goes
  /// through here first.
  static Future<bool> ours(String username, int service) async {
    final r = await (await Db.connect()).execute(
      Sql.named('SELECT count(*)::int FROM users WHERE username=@n AND service=@u'),
      parameters: {'n': username, 'u': service});
    return (r.first[0] as int) > 0;
  }

  static Future<List<String>> userPackages(String username) async {
    final r = await (await Db.connect()).execute(
      Sql.named('SELECT package_id FROM user_packages WHERE username=@u'),
      parameters: {'u': username},
    );
    return r.map((x) => x[0] as String).toList();
  }

  /// Overwrites the full set of a user's assignments (packages + grants) in one transaction.
  static Future<void> saveUser(String username, List<String> packages,
      List<String> plus, List<String> minus, int service,
      {bool all = false}) async {
    if (!all && !await ours(username, service)) return;
    final c = await Db.connect();
    await c.runTx((s) async {
      await s.execute(Sql.named('DELETE FROM user_packages WHERE username=@u'),
          parameters: {'u': username});
      for (final p in packages.toSet()) {
        await s.execute(
          Sql.named('INSERT INTO user_packages (username, package_id) VALUES (@u, @p)'),
          parameters: {'u': username, 'p': p},
        );
      }
      await s.execute(Sql.named('DELETE FROM user_permissions WHERE username=@u'),
          parameters: {'u': username});
      for (final g in plus.toSet()) {
        await s.execute(
          Sql.named('INSERT INTO user_permissions (username, permission, allow) VALUES (@u,@p,true)'),
          parameters: {'u': username, 'p': g},
        );
      }
      for (final g in minus.toSet()) {
        await s.execute(
          Sql.named('INSERT INTO user_permissions (username, permission, allow) VALUES (@u,@p,false)'),
          parameters: {'u': username, 'p': g},
        );
      }
    });
    await invalidate(username);
  }

  /// Creates an account IN A SERVICE. Without this parameter the account landed in service 0,
  /// i.e. a customer created a platform account for itself — and that one sees everyone.
  /// The new account has a password set by SOMEONE ELSE, so it immediately gets
  /// the must-change flag for the first sign-in — a password from an e-mail must not stay
  /// the working password for years.
  /// False = login taken anywhere (logins are global) — the caller shows one
  /// message for every collision, so a service cannot enumerate platform accounts or other services' accounts.
  static Future<bool> addUser(String username, String password, int service,
      {bool forceChange = true}) async {
    final r = await (await Db.connect()).execute(
      Sql.named('''INSERT INTO users (username, pass_hash, service, must_change_password)
                   VALUES (@u, @h, @s, @z) ON CONFLICT DO NOTHING'''),
      parameters: {
        'u': username, 'h': await Db.bcrypt(() => Db.hashPassword(password)),
        's': service, 'z': forceChange,
      },
    );
    return r.affectedRows == 1;
  }

  /// Password change BY AN ADMINISTRATOR — the owner now knows the employee's password,
  /// so the account must change it on the next visit.
  static Future<void> changePassword(String username, String password, int service,
      {bool all = false, bool forceChange = true}) async {
    await (await Db.connect()).execute(
      Sql.named('UPDATE users SET pass_hash=@h, must_change_password=@z WHERE username=@u'
          '${all ? '' : ' AND service=@s'}'),
      parameters: {
        'u': username, 'h': await Db.bcrypt(() => Db.hashPassword(password)),
        'z': forceChange,
        if (!all) 's': service,
      },
    );
    // a new password = end of the old sessions; a stolen session must not survive the change
    await Sessions.destroyAll(username);
  }

  /// Password attempt counter for a login+address pair at sign-in.
  static String attemptsKey(String login, String ip) => 'rl:login:${Sessions.hashToken('$login|${rateLimitAddress(ip)}')}';

  /// Counter of password confirmations in a signed-in session — only this account's sessions touch it.
  static String confirmationsKey(String login) => 'rl:confirm:${Sessions.hashToken(login)}';

  /// How many wrong password confirmations in a signed-in session before the account's sessions are closed.
  static const maxConfirmations = 5;

  /// Password of the signed-in account (password change, disabling 2FA). Limit as for sign-in, and after
  /// [maxConfirmations] failures all sessions of the account end — a hijacked session does not guess
  /// the password forever or fire a bcrypt isolate on every request (SEC-A-15).
  ///
  /// The account's own counter ([confirmationsKey]), not shared with sign-in: five bad sign-ins by a stranger
  /// from the victim's address must not close her sessions on the next correct confirmation. [ip] stays
  /// in the signature for compatibility.
  static Future<bool> confirmPassword(String username, String password, String ip) async {
    final k = confirmationsKey(username);
    int n;
    try {
      n = await Redis.counter(k, 300);
    } catch (_) {
      return false; // fail-closed like sign-in
    }
    if (n > maxConfirmations) {
      await Sessions.destroyAll(username);
      return false;
    }
    if (await Db.checkLogin(username, password) == null) {
      if (n == maxConfirmations) await Sessions.destroyAll(username);
      return false;
    }
    try {
      await Redis.del(k);
    } catch (_) {}
    return true;
  }

  /// Change of the user's OWN password: requires the old one, clears the must-change flag
  /// and ends the other sessions. Returns an i18n key of the error, or an empty string.
  static Future<String> ownPassword(
      String username, String old, String fresh, String repeat, {required String ip}) async {
    final wrong = Db.passwordErrorKey(fresh);
    if (wrong != null) return wrong;
    if (fresh != repeat) return 'ignis.msg.password.repeat_mismatch';
    if (fresh == old) return 'ignis.msg.password.same_as_old';
    if (!await confirmPassword(username, old, ip)) {
      return 'ignis.msg.password.old_mismatch';
    }
    await (await Db.connect()).execute(
      Sql.named('UPDATE users SET pass_hash=@h, must_change_password=false WHERE username=@u'),
      parameters: {'u': username, 'h': await Db.bcrypt(() => Db.hashPassword(fresh))},
    );
    await Sessions.destroyAll(username);
    return '';
  }

  /// TOTP secret of the account (decrypted), or an empty string when 2FA is off.
  static Future<String> totpSecret(String username) async {
    final r = await (await Db.connect()).execute(
      Sql.named("SELECT coalesce(totp, '') FROM users WHERE username=@u"),
      parameters: {'u': username});
    if (r.isEmpty) return '';
    final v = r.first[0] as String;
    return v.isEmpty ? '' : Crypto.decrypt(v, context: 'totp|$username');
  }

  /// By the COLUMN, not by the decrypted secret: an unreadable ciphertext (key change, corruption)
  /// does not disable the second factor — sign-in stops at a code that cannot be checked (SEC-A-11).
  static Future<bool> hasTotp(String username) async {
    final r = await (await Db.connect()).execute(
      Sql.named("SELECT coalesce(totp, '') <> '' FROM users WHERE username=@u"),
      parameters: {'u': username});
    return r.isNotEmpty && r.first[0] == true;
  }

  /// Turns the second factor on or off. The secret is stored encrypted with the same
  /// key as the secrets in settings — a database copy without `IGNIS_KEY` does not
  /// allow generating codes.
  static Future<void> setTotp(String username, String secret) async {
    // at least 80 bits (16 base32 chars, RFC 4226 recommends 160) — a one-char "secret" is no factor at all
    if (secret.isNotEmpty && (secret.length < 16 || Totp.decode(secret) == null)) {
      throw ArgumentError('TOTP secret: at least 16 base32 characters');
    }
    await (await Db.connect()).execute(
      Sql.named('UPDATE users SET totp=@t WHERE username=@u'),
      parameters: {'u': username, 't': secret.isEmpty ? '' : Crypto.encrypt(secret, context: 'totp|$username')});
  }

  /// Back-office accounts of a service with whether they have a second factor —
  /// for the list in the permissions panel.
  static Future<Map<String, bool>> accountsTotp(List<String> logins) async {
    if (logins.isEmpty) return const {};
    final r = await (await Db.connect()).execute(
      Sql.named("SELECT username, coalesce(totp, '') <> '' FROM users WHERE username = ANY(@u)"),
      parameters: {'u': TypedValue(Type.textArray, logins)});
    return {for (final x in r) x[0] as String: x[1] == true};
  }

  static Future<void> deleteUser(String username, int service,
      {bool all = false}) async {
    if (!all && !await ours(username, service)) return;
    final c = await Db.connect();
    await c.runTx((s) async {
      await s.execute(Sql.named('DELETE FROM user_packages WHERE username=@u'),
          parameters: {'u': username});
      await s.execute(Sql.named('DELETE FROM user_permissions WHERE username=@u'),
          parameters: {'u': username});
      await s.execute(Sql.named('DELETE FROM users WHERE username=@u'), parameters: {'u': username});
    });
    await invalidate(username);
    await Sessions.destroyAll(username);
  }

  // ── site settings (key→value) ──

  /// Settings of ONE service. The parameter is required — with a default value
  /// one forgotten call would show a customer the platform configuration.
  /// [secrets] = false: no secret keys and no decryption — for the template model (PERF-A-2).
  static Future<Map<String, String>> settings(int service, {bool secrets = true}) async {
    // Cache in Redis: one request read this table 3–7 times (panel, mail,
    // signature, scheduler). The cache holds ENCRYPTED values — plaintext secrets
    // only in node memory, never in Redis.
    final key = 'settings:$service';
    Map<String, String>? rawSettings;
    try {
      final raw = await Redis.get(key);
      if (raw != null) rawSettings = (jsonDecode(raw) as Map).cast<String, String>();
    } catch (_) {}
    if (rawSettings == null) {
      final r = await (await Db.connect()).execute(
        Sql.named('SELECT key, value FROM settings WHERE service=@u ORDER BY key'),
        parameters: {'u': service},
      );
      rawSettings = {for (final x in r) x[0] as String: (x[1] ?? '') as String};
      try {
        await Redis.setEx(key, jsonEncode(rawSettings), 60);
      } catch (_) {}
    }
    // secrets (passwords, API keys) are stored encrypted — see crypto.dart. We decrypt ONLY
    // secret keys: a plain field with a pasted ciphertext must not be an oracle (SEC-A-8).
    return {
      for (final e in rawSettings.entries)
        if (!Crypto.isSecret(e.key))
          e.key: e.value
        else if (secrets)
          e.key: Crypto.decrypt(e.value, context: '$service|${e.key}')
    };
  }

  static Future<void> saveSetting(int service, String key, String value) async {
    final secret = Crypto.isSecret(key);
    if (!secret && Crypto.looksEncrypted(value)) {
      throw const FormatException('The value looks like a ciphertext (enc:…) — it is not saved.');
    }
    await (await Db.connect()).execute(
      Sql.named('''INSERT INTO settings (id, key, value, service) VALUES (@i, @k, @v, @u)
                   ON CONFLICT (id) DO UPDATE SET value = EXCLUDED.value'''),
      parameters: {
        'i': '$key@$service', 'k': key, 'u': service,
        'v': secret ? Crypto.encrypt(value, context: '$service|$key') : value,
      },
    );
    try {
      await Redis.del('settings:$service'); // AFTER the write — otherwise another node would rebuild the cache with the old value
    } catch (_) {}
  }
}
