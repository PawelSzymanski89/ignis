// Drops and creates an empty test database (tool/pg_test.sh) — connects with IGNIS_DB_* to the "postgres" database.
// With [role] [password]: the database owner is a regular role (no SUPERUSER or BYPASSRLS), as in production —
// a superuser bypasses RLS even with FORCE, so an isolation test on it would check nothing.
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
  if (a.length == 3) {
    final (role, password) = (a[1], a[2]);
    if (!RegExp(r'^[a-z_]+$').hasMatch(role) || !RegExp(r'^[a-z0-9]+$').hasMatch(password)) throw ArgumentError('role/password');
    if ((await c.execute(Sql.named('SELECT 1 FROM pg_roles WHERE rolname=@r'), parameters: {'r': role})).isEmpty) {
      await c.execute("CREATE ROLE $role LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD '$password'");
    }
    await c.execute('CREATE DATABASE $name OWNER $role');
  } else {
    await c.execute('CREATE DATABASE $name');
  }
  await c.close();
}
