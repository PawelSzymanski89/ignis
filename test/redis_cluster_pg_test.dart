// HARD-L.14.1: Redis.delMany works on Redis Cluster — keys in different hash slots are deleted one DEL each, not in one
// multi-key DEL (CROSSSLOT). A single-node cluster (all slots on one node) still refuses cross-slot commands.
// Run: tool/pg_test.sh test/redis_cluster_pg_test.dart (needs only redis-server)
import 'dart:io';

import 'package:ignis/engine/redis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main(List<String> a) async {
  if (Platform.environment['IGNIS_REDIS_HOST'] == null) {
    print('  skipped — no IGNIS_REDIS_HOST (tool/pg_test.sh)');
    return;
  }
  if (a.isEmpty) {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final dir = await Directory.systemTemp.createTemp('ignis-cluster');
    final server = await Process.start('redis-server', [
      '--port', '$port', '--bind', '127.0.0.1', '--cluster-enabled', 'yes',
      '--cluster-config-file', '${dir.path}/nodes.conf', '--dir', dir.path, '--save', '', '--appendonly', 'no',
    ]);
    Future<String> cli(List<String> args) async =>
        '${(await Process.run('redis-cli', ['-p', '$port', ...args])).stdout}'.trim();
    var code = 1;
    try {
      for (var i = 0; i < 50 && await cli(['PING']) != 'PONG'; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await cli(['CLUSTER', 'ADDSLOTSRANGE', '0', '16383']);
      for (var i = 0; i < 50 && !(await cli(['CLUSTER', 'INFO'])).contains('cluster_state:ok'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final p = await Process.start(Platform.resolvedExecutable, ['run', Platform.script.toFilePath(), 'child'],
          environment: {'IGNIS_REDIS_HOST': '127.0.0.1', 'IGNIS_REDIS_PORT': '$port'});
      p.stdout.listen(stdout.add);
      p.stderr.listen(stderr.add);
      code = await p.exitCode;
    } finally {
      server.kill();
      await server.exitCode;
      await dir.delete(recursive: true);
    }
    exit(code);
  }

  final keys = ['csess:a1', 'csess:b2', 'sess:c3', 'perm:d4'];
  for (final k in keys) {
    await Redis.set(k, 'x');
  }
  var crossSlot = false;
  try {
    await Redis.cmd(['DEL', ...keys]);
  } catch (e) {
    crossSlot = '$e'.contains('CROSSSLOT');
  }
  check('the server is a cluster: a multi-key DEL across slots is refused (CROSSSLOT)', crossSlot);
  await Redis.delMany(keys);
  for (final k in keys) {
    check('delMany deleted $k', await Redis.get(k) == null);
  }
  await Redis.delMany(const []);
  print('\nALL PASSED');
  exit(0);
}
