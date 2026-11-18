// ============================================================================
//  health_page.dart — "/health": the load balancer probe
// ----------------------------------------------------------------------------
//  Public and session-less, because Caddy queries it. It checks what the node
//  CANNOT serve the panel without: Postgres and Redis. Previously `health_uri` pointed
//  at `/`, a page that touches nothing — a node with a broken database connection
//  passed the test and kept getting traffic, returning 500 on every subpage.
//
//  ⚠️ A DELIBERATE TRADE-OFF: the database and Redis are SHARED by all nodes. When
//  Postgres goes down, all probes report a failure and Caddy drops the whole cluster from the pool — the user
//  sees a "service unavailable" page from the proxy instead of an app error. That is better than the
//  opposite (traffic sent to a node that cannot answer anyway), and the failure page
//  is handled by `handle_errors` in the Caddyfile.
//
//  MinIO deliberately does NOT affect the result: missing storage breaks only files, the rest of the panel
//  works. It is reported so the state is visible, but it does not take the node out of traffic.
// ============================================================================

import 'dart:io';

import '../engine/annotations.dart';
import '../engine/db.dart';
import '../engine/storage.dart';
import '../engine/page_engine.dart';
import '../engine/redis.dart';

@Page('/health', technical: true, noDb: true)
class HealthPage extends PageEngine {
  static const _limit = Duration(seconds: 2); // shorter than health_timeout in Caddy (3 s)

  @override
  Future<bool> doBeforeProcess() async {
    final node = Platform.environment['IGNIS_NODE'] ?? 'unknown';
    final db = await _check(() async =>
        (await Db.connect()).execute('SELECT 1').then((_) => true));
    final redis = await _check(() async {
      await Redis.set('health:$node', DateTime.now().toIso8601String());
      return true;
    });
    // storage for information only — see the comment at the top of the file
    final storage = await _check(() => Storage.client.bucketExists(Storage.bucket));

    final healthy = db && redis;
    status = healthy ? 200 : HttpStatus.serviceUnavailable;
    header('Cache-Control', 'no-store');
    json({
      'node': node,
      'healthy': healthy,
      'database': db ? 'ok' : 'error',
      'redis': redis ? 'ok' : 'error',
      'storage': storage ? 'ok' : 'error', // does not affect the status code
    });
    return false;
  }

  static Future<bool> _check(Future<bool> Function() test) async {
    try {
      return await test().timeout(_limit);
    } catch (_) {
      return false;
    }
  }
}
