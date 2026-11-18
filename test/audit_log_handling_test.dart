// Dziennik w usłudze: wpis platformy pokazuje „obsługa" i puste IP — login operatora nie wycieka
// ani w liście, ani w filtrze autorów, ani przez filtr `kto` / szukanie.
// Wymaga Postgresa: IGNIS_DB_HOST/PORT/USER/PASS/NAME (tabele tymczasowe, baza bez zmian).
import 'dart:io';

import 'package:ignis/engine/db.dart';
import 'package:ignis/engine/audit_log.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  if (Platform.environment['IGNIS_DB_HOST'] == null) {
    print('  pominięte — brak IGNIS_DB_HOST');
    return;
  }
  await Db.inContext(0, () async {
    final c = await Db.connect();
    // tymczasowe tabele przesłaniają prawdziwe w tej sesji (pg_temp jest pierwsze w search_path)
    await c.execute('CREATE TEMP TABLE services (id int, name text)');
    await c.execute('CREATE TEMP TABLE audit_log (id serial, service int, actor text, location text, action text, '
        "detail text, target int, ip text, occurred_at text, result text DEFAULT 'ok')");
    final now = DateTime.now().toIso8601String();
    await c.execute("INSERT INTO audit_log (service, actor, location, action, detail, target, ip, occurred_at) VALUES "
        "(5, 'ala', '/a', 'x', '', 0, '1.1.1.1', '$now'), (0, 'operator', '/a', 'y', '', 5, '9.9.9.9', '$now'), "
        "(0, 'operator', '/a', 'z', '', 7, '9.9.9.9', '$now'), (5, 'stary', '/a', 'x', '', 0, '', '2020-01-01')");

    final w = (await AuditLog.list(5)).where((x) => x.actor != 'stary').toList();
    check('usługa widzi swój wpis i wpis platformy u siebie', w.length == 2);
    final p = w.firstWhere((x) => x.service == 0);
    check('wpis platformy: „obsługa" i puste IP', p.actor == AuditLog.handler && p.ip == '');
    check('własny wpis z loginem i IP', w.any((x) => x.actor == 'ala' && x.ip == '1.1.1.1'));
    check('autorzy bez loginu operatora', !(await AuditLog.authors(5)).contains('operator'));
    check('filtr kto=operator nic nie zdradza', await AuditLog.count(5, actor: 'operator') == 0);
    check('szukanie po loginie operatora nic nie zdradza', await AuditLog.count(5, search: 'oper') == 0);
    check('filtr kto=obsługa działa', await AuditLog.count(5, actor: AuditLog.handler) == 1);
    check('filtr kto=ala tylko w swojej usłudze', await AuditLog.count(5, actor: 'ala') == 1 && await AuditLog.count(7, actor: 'ala') == 0);
    // FIX-25: keyset po id
    check('autorzy nie z dziennika (stary wpis nie trafia do filtra)', !(await AuditLog.authors(5)).contains('stary'));
    final ids = [for (final x in await AuditLog.list(0, all: true)) x.id];
    check('lista od najnowszych', ids.length == 4 && ids.first > ids.last);
    final older = await AuditLog.list(0, all: true, limit: 2, before: ids[1]);
    check('przed: dwa kolejne starsze', older.map((x) => x.id).join(',') == ids.sublist(2).join(','));
    final newer = await AuditLog.list(0, all: true, limit: 2, after: ids[3]);
    check('po: najbliższe nowsze, nadal od najnowszych', newer.map((x) => x.id).join(',') == ids.sublist(1, 3).join(','));
    final everything = await AuditLog.list(0, all: true);
    check('platforma widzi login i IP operatora',
        everything.where((x) => x.actor == 'operator' && x.ip == '9.9.9.9').length == 2);
  });
  exit(0);
}
