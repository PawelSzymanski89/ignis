// SEC-A-16 / FIX-7: domeny z mapy w pamięci noda — nazwa usługi z `|` nie przesuwa pól, nieznany Host nie kosztuje
// zapytania ani klucza w Redisie, zmiana widoczna po Tenanci.odswiez().
// Uruchomienie: tool/pg_test.sh test/domain_cache_pg_test.dart
import 'dart:io';

import 'package:ignis/engine/db.dart';
import 'package:ignis/engine/orm.dart';
import 'package:ignis/engine/schema.dart';
import 'package:ignis/engine/tenant.dart';
// ignore: unused_import
import 'package:ignis/entities.dart';
import 'package:postgres/postgres.dart' show Sql;

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

/// Liczba kluczy `domena:*` w Redisie testów (redis-cli, bo silnik nie ma KEYS).
Future<String> domainKeys() async =>
    (await Process.run('redis-cli', ['-p', Platform.environment['IGNIS_REDIS_PORT'] ?? '6379', 'EVAL',
            "return #redis.call('KEYS', 'domena:*')", '0']))
        .stdout
        .toString()
        .trim();

Future<void> main() async {
  if (Platform.environment['IGNIS_DB_HOST'] == null) {
    print('  pominięte — brak IGNIS_DB_HOST (tool/pg_test.sh)');
    return;
  }
  EntityRegistry.build();
  await Schema.sync();
  const domain = 'pipe-test.example';
  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute("DELETE FROM domains WHERE domain = 'pipe-test.example'");
    await c.execute("DELETE FROM services WHERE slug = 'pipetest'");
    final id = (await c.execute("INSERT INTO services (name, slug, active) VALUES ('Foo|1', 'pipetest', false) RETURNING id"))
        .first[0] as int;
    await c.execute(Sql.named('INSERT INTO domains (service, domain) VALUES (@u, @d)'), parameters: {'u': id, 'd': domain});
  });
  await Tenants.refresh();
  final z1 = await Tenants.fromHost(domain);
  check('nieaktywna, nazwa z | w całości', z1 != null && !z1.active && z1.name == 'Foo|1');

  final redisKeys = await domainKeys();
  var errors = 0;
  final sessionsBefore = DateTime.now();
  for (var i = 0; i < 200; i++) {
    if (await Tenants.fromHost('losowy$i.example') != null) errors++;
  }
  check('200 nieznanych hostów → null, bez kluczy w Redisie',
      errors == 0 && await domainKeys() == redisKeys);
  check('…i z pamięci (szybko, bez bazy)', DateTime.now().difference(sessionsBefore).inMilliseconds < 500);

  await Db.asSystem(() async => (await Db.connect()).execute("UPDATE services SET active = true WHERE slug = 'pipetest'"));
  check('bez odswiez — wciąż poprzedni stan (mapa w pamięci)', !(await Tenants.fromHost(domain))!.active);
  await Tenants.refresh();
  check('po odswiez — nowy stan', (await Tenants.fromHost(domain))!.active);
  check('domenySystemu policzone raz (ta sama lista)', identical(Tenants.systemDomains, Tenants.systemDomains));

  await Db.asSystem(() async {
    final c = await Db.connect();
    await c.execute("DELETE FROM domains WHERE domain = 'pipe-test.example'");
    await c.execute("DELETE FROM services WHERE slug = 'pipetest'");
  });
  await Tenants.refresh();
  check('usunięta domena → null', await Tenants.fromHost(domain) == null);
  print('\nALL PASSED');
  exit(0);
}
