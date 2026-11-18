// ============================================================================
//  shutdown.dart — graceful node shutdown (SIGTERM/SIGINT)
// ----------------------------------------------------------------------------
//  A rolling deploy sends SIGTERM. Without this, in-flight requests got a reset,
//  and the node's `lock:*` locks waited for their TTL (up to an hour), so background jobs
//  did not start on any node.
// ============================================================================

import 'dart:async';
import 'dart:io';

class Shutdown {
  final Set<Future<void>> _inFlight = {};

  /// Registers a request handler that shutdown will wait for.
  void track(Future<void> f) {
    _inFlight.add(f);
    f.whenComplete(() => _inFlight.remove(f));
  }

  int get inFlight => _inFlight.length;

  /// Stops accepting connections, waits for in-flight requests at most [limit],
  /// then drops the rest. Returns true when all of them finished on their own.
  Future<bool> close(HttpServer server, {Duration limit = const Duration(seconds: 20)}) async {
    final closing = server.close();
    var clean = true;
    await Future.wait(_inFlight.toList()).timeout(limit, onTimeout: () {
      clean = false;
      return const [];
    });
    if (!clean) await server.close(force: true);
    await closing;
    return clean;
  }
}
