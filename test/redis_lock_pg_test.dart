// SEC-040.11: background-job lock released/extended only by its owner (compare-and-delete / compare-and-expire).
// Reproduces the cross-node race: node A's lock expires (TTL), node B takes it over, then A's cleanup must NOT
// drop B's lock and A's keep-alive must NOT extend it. Needs only Redis (tool/pg_test.sh test/redis_lock_pg_test.dart).
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
  const k = 'lock:test:sec040';
  const node = 'node-A';
  await Redis.del(k);

  // A per-run token distinguishes two runs of the SAME node (node name alone would not).
  final tokenA = '$node:${Crypto.randomToken(8)}';
  final tokenA2 = '$node:${Crypto.randomToken(8)}';
  check('dwa przebiegi tego samego węzła mają różne tokeny', tokenA != tokenA2);

  // Node A takes the lock.
  check('A bierze wolną blokadę', await Redis.setNxEx(k, tokenA, 300));
  check('B nie wejdzie, póki blokada A żyje', !await Redis.setNxEx(k, '$node-B', 300));

  // A's work overruns the TTL: Redis drops the key, node B takes the lock over.
  await Redis.del(k); // symulacja wygaśnięcia TTL
  final tokenB = 'node-B:${Crypto.randomToken(8)}';
  check('B przejmuje blokadę po wygaśnięciu TTL A', await Redis.setNxEx(k, tokenB, 300));

  // A finishes and tries to release — the OLD bug (bezwarunkowe Redis.del) skasowałoby cudzą blokadę B.
  check('delIfEqual(A) NIE kasuje cudzej blokady B', !await Redis.delIfEqual(k, tokenA));
  check('blokada B nadal trzyma B', await Redis.get(k) == tokenB);

  // A's keep-alive must not extend B's lock either.
  check('expireIfEqual(A) NIE przedłuża cudzej blokady B', !await Redis.expireIfEqual(k, tokenA, 999));

  // Owner releases its own lock.
  check('B zdejmuje swoją blokadę', await Redis.delIfEqual(k, tokenB));
  check('blokada wolna', await Redis.get(k) == null);

  // Shutdown cleanup: releaseLocks must drop locks held with a `node:<token>` value too.
  await Redis.setNxEx(k, tokenA, 300);
  await Redis.releaseLocks(node);
  check('releaseLocks(node) zdejmuje blokadę z wartością node:<token>', await Redis.get(k) == null);

  await Redis.del(k);
  if (_bledy > 0) {
    print('\n$_bledy NOT PASSED');
    exit(1);
  }
  print('\nALL PASSED');
  exit(0);
}
