// IGNIS-050.3: Redis.runExclusive (one node at a time, keep-alive, owner-only release) and Ignis.every.
// Needs only Redis (tool/pg_test.sh test/run_exclusive_pg_test.dart).
import 'dart:async';
import 'dart:io';

import 'package:ignis/ignis.dart';
import 'pg_guard.dart';

var _bledy = 0;
void check(String description, bool condition) {
  if (!condition) _bledy++;
  print('  ${condition ? 'ok' : 'NOT PASSED'} — $description');
}

Future<void> main() async {
  if (skipDestructive()) return;
  const name = 'test:ignis0503';
  const k = 'lock:$name';
  await Redis.del(k);

  // Two parallel runs: exactly one body runs.
  var runs = 0;
  final r = await Future.wait([
    for (var i = 0; i < 2; i++)
      Redis.runExclusive(name, const Duration(seconds: 5), (_) async {
        runs++;
        await Future.delayed(const Duration(milliseconds: 300));
      }),
  ]);
  check('dwa równoległe runExclusive — wykonuje jeden', runs == 1 && r.where((x) => x).length == 1);
  check('blokada zwolniona po zakończeniu', await Redis.get(k) == null);

  // Keep-alive: ttl 3 s, body runs 5 s — the lock must survive past the ttl.
  bool? ownerLate;
  String? heldLate;
  await Redis.runExclusive(name, const Duration(seconds: 3), (owner) async {
    await Future.delayed(const Duration(milliseconds: 4500));
    ownerLate = owner();
    heldLate = await Redis.get(k);
  });
  check('heartbeat utrzymuje blokadę dłużej niż ttl', ownerLate == true && heldLate != null);

  // Lock lost: another node overwrites it — stillOwner turns false and its lock is not deleted.
  bool? ownerAfter;
  await Redis.runExclusive(name, const Duration(seconds: 3), (owner) async {
    await Redis.set(k, 'node-B:obca');
    for (var i = 0; i < 30 && owner(); i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    ownerAfter = owner();
  });
  check('utrata blokady (SET innej wartości) → stillOwner false', ownerAfter == false);
  check('cudza blokada nie skasowana', await Redis.get(k) == 'node-B:obca');
  await Redis.del(k);

  // confirmExclusive sees the takeover at once (keep-alive with ttl 30 s would not fire for 10 s).
  bool? confirmedOwn, confirmedLost, flagAfter;
  await Redis.runExclusive(name, const Duration(seconds: 30), (owner) async {
    confirmedOwn = await Redis.confirmExclusive(name);
    await Redis.set(k, 'node-B:obca');
    confirmedLost = await Redis.confirmExclusive(name);
    flagAfter = owner();
  });
  check('confirmExclusive: true dla własnej, false zaraz po przejęciu',
      confirmedOwn == true && confirmedLost == false && flagAfter == false);
  check('confirmExclusive: brak przebiegu → false', !await Redis.confirmExclusive(name));
  check('confirmExclusive: cudza blokada nie skasowana', await Redis.get(k) == 'node-B:obca');
  await Redis.del(k);

  // Lock lost by DEL.
  bool? ownerDel;
  await Redis.runExclusive(name, const Duration(seconds: 3), (owner) async {
    await Redis.del(k);
    for (var i = 0; i < 30 && owner(); i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    ownerDel = owner();
  });
  check('utrata blokady (DEL) → stillOwner false', ownerDel == false);

  // Ignis.every: an error does not kill the timer; stopJobs stops it.
  var ticks = 0;
  Ignis.every(name, const Duration(milliseconds: 200), const Duration(seconds: 5), (_) async {
    ticks++;
    throw StateError('celowy błąd');
  });
  await Future.delayed(const Duration(milliseconds: 1100));
  check('every: błąd nie zabija timera (${ticks} przebiegów)', ticks >= 3);
  Ignis.stopJobs();
  final stopped = ticks;
  await Future.delayed(const Duration(milliseconds: 600));
  check('every: stopJobs zatrzymuje timer', ticks == stopped);
  check('every: blokada zwolniona mimo błędu', await Redis.get(k) == null);

  await Redis.del(k);
  if (_bledy > 0) {
    print('\n$_bledy NOT PASSED');
    exit(1);
  }
  print('\nALL PASSED');
  exit(0);
}
