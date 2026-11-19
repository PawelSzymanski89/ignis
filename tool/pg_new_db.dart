// Drops and creates an empty test database (tool/pg_test.sh) — connects with IGNIS_DB_* to the "postgres" database.
// With [role] [password]: the database owner is a regular role (no SUPERUSER or BYPASSRLS), as in production —
// a superuser bypasses RLS even with FORCE, so an isolation test on it would check nothing.
// With [runtimeRole] [runtimePassword] as well: a second regular role that owns nothing — the owner grants it
// DML later (SECURITY.md, "Runtime database role"); test/runtime_role_pg_test.dart runs the node on it.
import 'dart:io';

import 'package:postgres/postgres.dart';

Future<void> main(List<String> a) async {
  final name = a.first;
  if (!RegExp(r'^[a-z_]+test$').hasMatch(name)) throw ArgumentError('only *test databases: $name');
  final e = Platform.environment;
  final c = await Connection.open(
      Endpoint(host: e['IGNIS_DB_HOST']!, port: int.parse(e['IGNIS_DB_PORT']!), database: 'postgres', username: e['IGNIS_DB_USER'], password: e['IGNIS_DB_PASS']),
      settings: const ConnectionSettings(sslMode: SslMode.disable));
  await c.execute('DROP DATABASE IF EXISTS $name');
  if (a.length >= 3) {
    for (var i = 1; i + 1 < a.length; i += 2) {
      final (role, password) = (a[i], a[i + 1]);
      if (!RegExp(r'^[a-z_]+$').hasMatch(role) || !RegExp(r'^[a-z0-9]+$').hasMatch(password)) throw ArgumentError('role/password');
      if ((await c.execute(Sql.named('SELECT 1 FROM pg_roles WHERE rolname=@r'), parameters: {'r': role})).isEmpty) {
        await c.execute("CREATE ROLE $role LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD '$password'");
      }
    }
    await c.execute('CREATE DATABASE $name OWNER ${a[1]}');
  } else {
    await c.execute('CREATE DATABASE $name');
  }
  await c.close();
}
