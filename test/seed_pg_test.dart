// SEC-A-1: zasiew nie robi roota z konta platformy bez pakietów — tylko z konta admin założonego w tym przebiegu.
// FIX-10: hasło z IGNIS_ADMIN_PASS nie jest wypisywane.
// Uruchomienie: tool/pg_test.sh test/seed_pg_test.dart
import 'dart:io';

import 'package:ignis/engine/db.dart';
import 'package:ignis/engine/orm.dart';
import 'package:ignis/engine/schema.dart';
import 'package:ignis/engine/seed.dart';
// ignore: unused_import — encje rdzenia rejestrują się przez mirrors (EntityRegistry.build)
import 'package:ignis/entities.dart';
import 'package:postgres/postgres.dart' show Sql;

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main(List<String> a) async {
  if (Platform.environment['IGNIS_DB_HOST'] == null) {
    print('  pominięte — brak IGNIS_DB_HOST (tool/pg_test.sh)');
    return;
  }
  EntityRegistry.build();
  await Schema.sync();
  if (a.contains('zasiew')) {
    await Seed.seed();
    exit(0);
  }
  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute('DELETE FROM user_packages');
    await c.execute('DELETE FROM users');
    Future<List<String>> packages(String u) async => [
          for (final r in await c.execute(Sql.named('SELECT package_id FROM user_packages WHERE username=@u'),
              parameters: {'u': u}))
            r[0] as String
        ];

    await Seed.seed();
    check('świeży admin dostaje root', (await packages('admin')).contains('root'));

    await c.execute(Sql.named("INSERT INTO users (username, pass_hash, realm, service) VALUES (@u, '', 'staff', 0)"),
        parameters: {'u': 'nowy'});
    await c.execute(Sql.named("DELETE FROM user_packages WHERE username='admin'"));
    await Seed.seed();
    check('konto platformy bez pakietów NIE zostaje rootem po restarcie', (await packages('nowy')).isEmpty);
    check('istniejący admin odchudzony z pakietów NIE wraca do roota', (await packages('admin')).isEmpty);
  });
  // FIX-10: hasło podane w IGNIS_ADMIN_PASS nie trafia na konsolę (journald / log kontenera)
  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute('DELETE FROM user_packages');
    await c.execute('DELETE FROM users');
  });
  await Db.close();
  const given = 'Podane-Haslo-Operatora-77';
  final r = await Process.run(Platform.resolvedExecutable, ['run', Platform.script.toFilePath(), 'zasiew'],
      environment: {'IGNIS_ADMIN_PASS': given});
  check('podane IGNIS_ADMIN_PASS nie jest wypisywane',
      r.exitCode == 0 && !'${r.stdout}${r.stderr}'.contains(given) && '${r.stdout}'.contains('password from IGNIS_ADMIN_PASS'));
  print('\nALL PASSED');
}
