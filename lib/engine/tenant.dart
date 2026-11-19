// ============================================================================
//  tenant.dart — service (tenant) context for a request
// ----------------------------------------------------------------------------
//  Addresses:
//    example.com          → the service's public front
//    admin.example.com    → the panel of THAT service
//    admin.<system-domain> → the PLATFORM panel (sees all services)
//
//  The service is resolved from the Host header, ONCE, before the page lifecycle starts. Not from
//  a parameter, not from the session — both can be swapped, and the domain is
//  what the browser actually visited.
//
//  Isolation stands on three layers, and each alone is too weak:
//    1. context from the domain (here),
//    2. enforced filter in the data layer,
//    3. RLS in Postgres — the last line, when code forgets the filter.
//
//  The session cookie is host-only, so a sign-in on admin.example.com
//  is never sent by the browser to admin.example.org. Session isolation is enforced by
//  the protocol, not our code — and good, because the protocol has no bad days.
// ============================================================================

import 'dart:io';

import 'db.dart';

class TenantContext {
  const TenantContext({required this.service, required this.name, required this.domain,
      required this.panel, required this.active, this.reason = ''});

  /// 0 = platform (system panel), >0 = a specific service.
  final int service;
  final String name;
  final String domain;

  /// Whether we landed under `admin.<domain>` (panel) or the public front.
  final bool panel;
  final bool active;

  /// Why the service is not working — goes to the page the visitor will see.
  final String reason;



  bool get platform => service == 0;

  static const platformContext = TenantContext(
      service: 0, name: 'Platform', domain: '', panel: true, active: true);
}

class Tenants {
  /// System domains — the platform works under them (and their `admin.`).
  /// A list, because the product address gets changed and the old one must keep working:
  /// links in e-mails and bookmarks do not stop being clicked after a rename.
  /// The first one is CANONICAL — subdomains of new services are built from it.
  static final List<String> systemDomains = List.unmodifiable(
      (Platform.environment['IGNIS_DOMAINS'] ??
              (throw StateError('Missing IGNIS_DOMAINS (comma-separated list of system domains)')))
          .split(',')
          .map((s) => s.trim().toLowerCase())
          .where((s) => s.isNotEmpty));

  /// Domain under which service subdomains are created.
  static String get systemDomain => systemDomains.first;

  /// How often the in-memory domain map of the node re-reads the database — it also holds whether a service is active.
  static Duration refreshing = const Duration(seconds: 30);

  /// DNS name: labels a-z0-9 and `-` of 1–63 characters, 253 in total.
  static final _hostName = RegExp(r'^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');

  /// Resolves the service from the Host header. Returns null when the domain is unknown —
  /// then we do not guess, we refuse to serve.
  static Future<TenantContext?> fromHost(String? host) async {
    if (host == null || host.isEmpty) return null;
    var h = host.split(':').first.toLowerCase(); // without the port
    // random garbage in Host costs neither a database query nor a Redis key
    if (!_hostName.hasMatch(h)) return null;
    final panel = h.startsWith('admin.');
    if (panel) h = h.substring('admin.'.length);

    if (systemDomains.contains(h)) {
      // Under the system domain the platform panel works ALSO without the `admin.` prefix.
      return TenantContext(
          service: 0, name: 'Platform', domain: h, panel: true, active: true);
    }

    final u = await _find(h);
    if (u == null) return null;

    // Subdomains in OUR zone serve the panel also without the `admin.` prefix.
    // The reason is hard: `admin.demo.<system-domain>` sits two levels under
    // the wildcard, and Let's Encrypt issues wildcards for one level only —
    // such a name cannot be covered by a certificate without a separate order for
    // every customer. So the customer panel lives under `<address>/admin`.
    // Own domains (`example.com`) are not affected: there `admin.example.com`
    // is the first level and works normally.
    final ourSubdomain = systemDomains.any((d) => h.endsWith('.$d'));
    return TenantContext(
        service: u.$1, name: u.$2, domain: h, panel: panel || ourSubdomain,
        active: u.$3, reason: u.$4);
  }

  /// (id, name, active, reason) for a domain — from the map of all domains in node memory. An unknown Host
  /// costs no query or Redis key (random headers do not flood the pool); the map reads the database in one
  /// query every [refreshing] and after [refresh].
  static Future<(int, String, bool, String)?> _find(String domain) async => (await _map())[domain];

  static Map<String, (int, String, bool, String)>? _domains;
  static DateTime _validUntil = DateTime(0);
  static Future<Map<String, (int, String, bool, String)>>? _loading;

  static Future<Map<String, (int, String, bool, String)>> _map() async {
    final m = _domains;
    if (m != null && DateTime.now().isBefore(_validUntil)) return m;
    // one load at a time; parallel requests wait for it
    return _loading ??= _load().then((fresh) {
      _domains = fresh;
      _validUntil = DateTime.now().add(refreshing);
      return fresh;
    }, onError: (Object e) {
      if (m == null) throw e;
      stderr.writeln('Ignis domains: refresh failed, keeping the previous map — $e');
      _validUntil = DateTime.now().add(const Duration(seconds: 5));
      return m;
    }).whenComplete(() => _loading = null);
  }

  static Future<Map<String, (int, String, bool, String)>> _load() async {
    // before the request context — this query is what DETERMINES the service, hence system context
    final r = await Db.asSystem(() async => (await Db.connect()).execute(
        'SELECT d.domain, u.id, u.name, u.active FROM domains d JOIN services u ON u.id = d.service'));
    return {
      for (final w in r)
        (w[0] as String).toLowerCase(): (
          w[1] as int,
          w[2] as String,
          w[3] as bool,
          w[3] as bool ? '' : 'The site is disabled.',
        )
    };
  }

  /// After every change in services or domains: this node reads the map on the next request,
  /// the others — at the latest after [refreshing].
  static Future<void> refresh() async {
    _validUntil = DateTime(0);
  }
}
