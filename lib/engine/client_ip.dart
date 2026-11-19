// ============================================================================
//  client_ip.dart — client address for attempt limits and the audit log
// ----------------------------------------------------------------------------
//  Everyone along the way appends to X-Forwarded-For, so its FIRST entry is written by the
//  client itself. We trust the header only when the connection came from our
//  proxy (IGNIS_TRUSTED_PROXIES), and take the first entry from the right outside the proxies.
// ============================================================================

import 'dart:io';
import 'dart:typed_data';

/// Trusted proxies from `IGNIS_TRUSTED_PROXIES` (IPs or CIDRs, comma-separated; `none` — no proxy).
final List<String> trustedProxies = parseTrustedProxies(Platform.environment['IGNIS_TRUSTED_PROXIES'] ?? '');

List<String> parseTrustedProxies(String raw) =>
    raw.trim() == 'none' ? const [] : raw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

/// Warning for the operator when [xff] came from a proxy on a private/loopback network and [trusted] is empty:
/// all clients then have the proxy address, so 30 bad sign-in attempts lock sign-in for everyone,
/// and the audit log records the proxy address. Null — all is well. Once per process ([clientAddress]).
String? proxyWarning(String connection, String? xff, List<String> trusted) {
  if (trusted.isNotEmpty || xff == null || xff.trim().isEmpty) return null;
  final a = InternetAddress.tryParse(connection.startsWith('::ffff:') ? connection.substring(7) : connection);
  if (a == null || !(a.isLoopback || _private(a))) return null;
  return 'Ignis WARNING: X-Forwarded-For from $connection, but IGNIS_TRUSTED_PROXIES is empty — all clients '
      'have the proxy address: sign-in limits block everyone at once, the audit log records the proxy address. '
      'Set IGNIS_TRUSTED_PROXIES=$connection (or the CIDR of the proxy network).';
}

bool _warned = false;

bool _private(InternetAddress a) {
  final b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) {
    return b[0] == 10 || (b[0] == 172 && b[1] & 0xf0 == 16) || (b[0] == 192 && b[1] == 168) || (b[0] == 100 && b[1] & 0xc0 == 64);
  }
  return b[0] & 0xfe == 0xfc || a.isLinkLocal; // ULA fc00::/7, fe80::/10
}

/// Client address: [connection] (socket address), and when that is a trusted proxy —
/// the first [xff] entry from the right outside [trusted].
String clientAddress(String connection, String? xff, List<String> trusted) {
  if (!_warned) {
    final o = proxyWarning(connection, xff, trusted);
    if (o != null) {
      _warned = true;
      stderr.writeln(o);
    }
  }
  if (!_trusted(connection, trusted)) return connection;
  final entries = (xff ?? '').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  for (final w in entries.reversed) {
    if (!_trusted(w, trusted)) return w;
  }
  return entries.isEmpty ? connection : entries.first;
}

/// Whether a technical route (health probe) may answer: a socket from loopback or from a trusted
/// proxy and without [xff] — a client request forwarded by the proxy carries XFF, the proxy's probe does not.
/// The Host header is written by the client, so it decides nothing here.
bool probeAllowed(String connection, String? xff, List<String> trusted) {
  if (xff != null && xff.trim().isNotEmpty) return false;
  final a = InternetAddress.tryParse(connection.startsWith('::ffff:') ? connection.substring(7) : connection);
  return (a?.isLoopback ?? false) || _trusted(connection, trusted);
}

/// Address for attempt-limit keys: IPv6 truncated to /64 (what one subscriber gets — the full address
/// gave them 2^64 fresh counters), IPv4 and non-addresses unchanged.
String rateLimitAddress(String ip) {
  final a = _bytes(ip);
  if (a == null || a.length != 16) return ip;
  final b = [...a.take(8), ...List.filled(8, 0)];
  return '${InternetAddress.fromRawAddress(Uint8List.fromList(b)).address}/64';
}

bool _trusted(String ip, Iterable<String> trusted) {
  final a = _bytes(ip);
  if (a == null) return false;
  for (final z in trusted) {
    final [network, ...rest] = z.split('/');
    final b = _bytes(network);
    if (b == null || b.length != a.length) continue;
    final bits = rest.isEmpty ? a.length * 8 : int.tryParse(rest.first) ?? -1;
    if (bits < 0 || bits > a.length * 8) continue;
    if (_prefix(a, b, bits)) return true;
  }
  return false;
}

List<int>? _bytes(String ip) {
  final s = ip.startsWith('::ffff:') && ip.contains('.') ? ip.substring(7) : ip;
  return InternetAddress.tryParse(s)?.rawAddress;
}

bool _prefix(List<int> a, List<int> b, int bits) {
  for (var i = 0; i < bits; i++) {
    final m = 0x80 >> (i % 8);
    if ((a[i ~/ 8] & m) != (b[i ~/ 8] & m)) return false;
  }
  return true;
}
