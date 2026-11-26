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

  // Shutdown: abandonExclusive turns stillOwner() false for a running body and waits for it, so releaseLocks
  // never frees a lock whose run still goes on (another node would run the same job alongside).
  var bodyDone = false;
  bool? ownerSeen;
  final run = Redis.runExclusive(name, const Duration(seconds: 30), (owner) async {
    for (var i = 0; i < 100 && owner(); i++) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    ownerSeen = owner();
    bodyDone = true;
  });
  await Future.delayed(const Duration(milliseconds: 200));
  await Redis.abandonExclusive(wait: const Duration(seconds: 3));
  check('abandonExclusive: stillOwner false, przebieg zakończony przed powrotem', bodyDone && ownerSeen == false);
  check('abandonExclusive: confirmExclusive false', !await Redis.confirmExclusive(name));
  await run;
  check('abandonExclusive: blokada zwolniona przez sam przebieg', await Redis.get(k) == null);

  // A body that ignores stillOwner and outlives the wait: its token comes back and releaseLocks keeps its lock
  // (the TTL frees it later) — freeing it would let another node run the same job alongside.
  final slow = Redis.runExclusive(name, const Duration(seconds: 30), (_) async {
    await Future.delayed(const Duration(milliseconds: 1500));
  });
  await Future.delayed(const Duration(milliseconds: 100));
  final still = await Redis.abandonExclusive(wait: const Duration(milliseconds: 200));
  await Redis.releaseLocks(Redis.lockNode, keep: still);
  check('abandonExclusive: trwający przebieg zwrócony, releaseLocks zostawia jego blokadę',
      still.length == 1 && await Redis.get(k) == still.first);
  await slow;
  check('po zakończeniu przebieg zwalnia blokadę sam', await Redis.get(k) == null);

  // IGNIS-050.11 (a): maxRun — after it the run is no longer owner and the keep-alive stops extending the lock
  // (it expires after ttl), even though the body ignores stillOwner and keeps going.
  bool? ownerEarly, ownerAfterMax, confirmAfterMax;
  String? heldAfterTtl;
  await Redis.runExclusive(name, const Duration(seconds: 2), maxRun: const Duration(milliseconds: 800), (owner) async {
    await Future.delayed(const Duration(milliseconds: 300));
    ownerEarly = owner();
    await Future.delayed(const Duration(milliseconds: 900));
    ownerAfterMax = owner();
    confirmAfterMax = await Redis.confirmExclusive(name);
    await Future.delayed(const Duration(milliseconds: 2500)); // > ttl since the last extension
    heldAfterTtl = await Redis.get(k);
  });
  check('maxRun: przed limitem owner true', ownerEarly == true);
  check('maxRun: po limicie stillOwner false i confirmExclusive false',
      ownerAfterMax == false && confirmAfterMax == false);
  check('maxRun: heartbeat nie przedłuża — blokada wygasa po ttl', heldAfterTtl == null);
  // maxRun via Ignis.every
  bool? everyOwnerAfterMax;
  final everyDone = Completer<void>();
  final t = Ignis.every(name, const Duration(milliseconds: 100), const Duration(seconds: 5),
      maxRun: const Duration(milliseconds: 300), (owner) async {
    if (everyDone.isCompleted) return;
    await Future.delayed(const Duration(milliseconds: 600));
    everyOwnerAfterMax = owner();
    everyDone.complete();
  });
  await everyDone.future;
  t.cancel();
  check('every(maxRun): po limicie stillOwner false', everyOwnerAfterMax == false);
  await Future.delayed(const Duration(milliseconds: 300));
  await Redis.del(k);

  // IGNIS-050.11 (b): without IGNIS_NODE the lock token prefix is a per-process id, not the shared 'node' —
  // releaseLocks of another node without IGNIS_NODE ('node') must not delete our lock.
  final envNode = Platform.environment['IGNIS_NODE'] ?? '';
  check('lockNode: ustawiony, niepusty', Redis.lockNode.isNotEmpty && Redis.lockNode == Redis.lockNode);
  if (envNode.isEmpty) {
    check('lockNode: bez IGNIS_NODE różny od "node" (${Redis.lockNode})', Redis.lockNode != 'node');
    String? held, afterOther;
    await Redis.runExclusive(name, const Duration(seconds: 10), (_) async {
      held = await Redis.get(k);
      await Redis.releaseLocks('node'); // another node without IGNIS_NODE shutting down
      afterOther = await Redis.get(k);
      await Redis.releaseLocks(Redis.lockNode, keep: [held!]);
    });
    check('token blokady z prefiksem lockNode', held != null && held!.startsWith('${Redis.lockNode}:'));
    check('releaseLocks("node") innego węzła nie kasuje naszej blokady', afterOther == held);
    // our own releaseLocks (shutdown) does remove it
    await Redis.set(k, '${Redis.lockNode}:xyz');
    await Redis.releaseLocks(Redis.lockNode);
    check('releaseLocks(lockNode) kasuje własną blokadę', await Redis.get(k) == null);
  } else {
    check('lockNode == IGNIS_NODE gdy ustawione', Redis.lockNode == envNode);
  }

  await Redis.del(k);
  if (_bledy > 0) {
    print('\n$_bledy NOT PASSED');
    exit(1);
  }
  print('\nALL PASSED');
  exit(0);
}
