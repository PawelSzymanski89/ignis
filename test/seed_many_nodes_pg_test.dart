// IGNIS-050.9: the real Ignis.start(seed: …) on TWO processes sharing one database and Redis (different
// IGNIS_PORT / IGNIS_NODE). The seed callbacks run one at a time under the start-up advisory lock, each node
// runs its own (so it must be idempotent — not exactly-once), the HTTP port listens only after the node has
// left the lock, and an exception in the callback ends the process with an error and frees the lock.
// Run: tool/pg_test.sh test/seed_many_nodes_pg_test.dart
import 'dart:async';
import 'dart:io';

import 'package:ignis/ignis.dart';
import 'package:ignis/ignis_registry.g.dart';
import 'pg_guard.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

int now() => DateTime.now().microsecondsSinceEpoch;

/// Child: a node whose seed logs start/end with its name and sleeps 2 s; SEED_FAIL=1 throws after the sleep.
Future<void> node() async {
  final name = Platform.environment['IGNIS_NODE']!;
  Future<void> log(String phase) async {
    final c = await Db.connect();
    await c.execute('CREATE TABLE IF NOT EXISTS seed_log (node text, phase text, at bigint)');
    await c.execute("INSERT INTO seed_log VALUES ('$name', '$phase', ${now()})");
  }

  await Ignis.start(
    registry: ignisRegistry,
    seed: () async {
      await log('start');
      await Future<void>.delayed(const Duration(seconds: 2));
      if (Platform.environment['SEED_FAIL'] == '1') throw StateError('seed failed on purpose');
      await log('end');
    },
  );
}

class Node {
  Node(this.name, this.port, this.process) {
    process.stdout.listen((b) => out.write(String.fromCharCodes(b)));
    process.stderr.listen((b) => out.write(String.fromCharCodes(b)));
    unawaited(process.exitCode.then((c) => exit = c));
    unawaited(_probe());
  }

  /// Every child started, killed when the test ends (a failed check must not leave nodes holding DB sessions).
  static final all = <Node>[];
  void _register() => all.add(this);
  final String name;
  final int port;
  final Process process;
  final out = StringBuffer();
  int? exit;

  /// First moment the HTTP port accepted a connection (polled every 20 ms).
  int? listening;

  Future<void> _probe() async {
    while (listening == null && exit == null) {
      try {
        final s = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(milliseconds: 200));
        listening = now();
        s.destroy();
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  }

  static Future<Node> start(String name, {bool fail = false}) async {
    final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = free.port;
    await free.close();
    final p = await Process.start(
      Platform.resolvedExecutable,
      ['run', Platform.script.toFilePath(), 'node'],
      environment: {
        'IGNIS_NODE': name,
        'IGNIS_TRUSTED_PROXIES': 'none',
        'IGNIS_PORT': '$port',
        if (fail) 'SEED_FAIL': '1',
      },
    );
    return Node(name, port, p).._register();
  }

  Future<bool> until(bool Function() ok, Duration limit) async {
    final end = DateTime.now().add(limit);
    while (!ok() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return ok();
  }

  Future<void> stop() async {
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}

Future<Map<String, Map<String, int>>> rows() => Db.asSystemSession(() async {
  final c = await Db.connect();
  final r = await c.execute("SELECT to_regclass('seed_log') IS NOT NULL");
  final out = <String, Map<String, int>>{};
  if (r.first[0] != true) return out;
  for (final row in await c.execute('SELECT node, phase, at FROM seed_log')) {
    (out[row[0] as String] ??= {})[row[1] as String] = row[2] as int;
  }
  return out;
});

Future<void> main(List<String> a) async {
  if (a.isNotEmpty) return node();
  if (skipDestructive()) return;
  try {
    await scenarios();
  } finally {
    for (final n in Node.all) {
      if (n.exit == null) n.process.kill(ProcessSignal.sigkill);
    }
  }
}

Future<void> scenarios() async {
  await Db.asSystemSession(() async => (await Db.connect()).execute('DROP TABLE IF EXISTS seed_log'));

  // 1. two nodes at once
  final na = await Node.start('node-a'), nb = await Node.start('node-b');
  final up = await na.until(
    () => na.listening != null && nb.listening != null || na.exit != null || nb.exit != null,
    const Duration(seconds: 120),
  );
  if (!up || na.listening == null || nb.listening == null)
    print("A exit ${na.exit}: ${na.out}\nB exit ${nb.exit}: ${nb.out}");
  check('both nodes started and listen', up && na.listening != null && nb.listening != null);
  final log = await rows();
  final a1 = log['node-a']!, b1 = log['node-b']!;
  check('each node ran its own seed callback (start and end of node-a and node-b)', a1.length == 2 && b1.length == 2);
  final (first, second) = a1['start']! < b1['start']! ? (a1, b1) : (b1, a1);
  check('the callbacks do not overlap (second starts after first ends)', second['start']! >= first['end']!);
  check('node-a listens only after its own callback ended', na.listening! > a1['end']!);
  check('node-b listens only after its own callback ended', nb.listening! > b1['end']!);
  final late = a1['start']! < b1['start']! ? nb : na;
  check(
    'the node that waited for the lock listens only after the other callback ended too',
    late.listening! > first['end']!,
  );
  await na.stop();
  await nb.stop();

  // 2. an exception in the callback: the process fails, the lock is freed, the other node starts
  await Db.asSystemSession(() async => (await Db.connect()).execute('DELETE FROM seed_log'));
  final nf = await Node.start('node-fail', fail: true);
  check('the failing node entered its callback', await _seen('node-fail', nf));
  final nc = await Node.start('node-c'); // starts while node-fail holds the lock
  await nf.until(() => nf.exit != null, const Duration(seconds: 60));
  if (nf.exit == 0 || nf.exit == null) print(nf.out);
  check('the failing node exits with an error (exit ${nf.exit})', nf.exit != null && nf.exit != 0);
  check('…and never listened', nf.listening == null);
  final cUp = await nc.until(() => nc.listening != null || nc.exit != null, const Duration(seconds: 120));
  if (!cUp || nc.listening == null) print(nc.out);
  check('the other node got the lock, seeded and listens', nc.listening != null);
  final log2 = await rows();
  check(
    'node-fail logged start without end, node-c ran after it',
    log2['node-fail']!['end'] == null && log2['node-c']!['start']! > log2['node-fail']!['start']!,
  );
  await nc.stop();
  await Db.asSystemSession(() async => (await Db.connect()).execute('DROP TABLE seed_log'));
  await Db.close();
}

Future<bool> _seen(String name, Node n) async {
  final end = DateTime.now().add(const Duration(seconds: 120));
  while (DateTime.now().isBefore(end) && n.exit == null) {
    if ((await rows())[name]?['start'] != null) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  print(n.out);
  return false;
}
