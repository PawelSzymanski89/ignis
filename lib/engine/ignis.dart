// ============================================================================
//  ignis.dart — Ignis node startup (called from the app's main)
// ----------------------------------------------------------------------------
//  Configured via env:
//    IGNIS_PORT       (8080 by default)
//    IGNIS_BIND       (listen address, 127.0.0.1 by default — proxy on another host: a private network address or 0.0.0.0)
//    IGNIS_NODE       (node label — visible in pages)
//    IGNIS_SCHEMA     (update | validate | none — auto-schema from @Entity, update by default)
//    IGNIS_DB_POOL    (pool size, 16 by default — one request = one connection, see RLS)
//    IGNIS_ASSETS     (theme static directory, 'web/assets' by default)
//    IGNIS_ADMIN_PASS (admin account password on first start; missing → random, printed to the console)
//    (DB: IGNIS_DB_* — see lib/engine/db.dart)
//  Compression: the node gzips only /assets/ static files (with ETag and 304). HTML pages go
//  uncompressed (CSRF token next to echoed input = BREACH) — gzip for them is the proxy's decision.
// ============================================================================

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../ignis_registry.g.dart' as core;
import 'client_ip.dart';
import 'db.dart';
import 'audit_log.dart';
import 'engine.dart';
import 'config.dart';
import 'storage.dart';
import 'orm.dart';
import 'redis.dart';
import 'registry.dart';
import 'registry_fingerprint.dart';
import 'render.dart';
import 'schema.dart';
import 'seed.dart';
import 'crypto.dart';
import 'i18n.dart';
import 'shutdown.dart';

class Ignis {
  /// App permissions (key, description) — appended to the core catalog ([Seed.catalog]).
  static List<(String, String)> permissions = const [];

  /// App settings sections — the settings panel shows only these.
  static List<Section> settingsSections = const [];

  /// Permanent 301 redirects (old path → new), the query is kept — see [dispatch].
  static Map<String, String> redirects = const {};

  /// When set, `/` redirects 302 here.
  static String? homePage;

  /// Product name of the panel — in templates as `{{ product }}`.
  static String brand = 'Ignis';

  /// Static directories under `/assets/` (app before library) — set in [start].
  static List<String> assetDirs = const [];

  /// Public directories under their own prefixes (e.g. a browser SDK under `/sdk/`) — see [Mount].
  static List<Mount> mounts = const [];

  /// Where "Back" on the error page leads (an app with its own panel gives its dashboard).
  static String errorBackUrl = '/admin';

  static final List<Timer> _jobs = [];

  /// Background job: every [interval] runs [body] under [Redis.runExclusive] (one node at a time cluster-wide,
  /// no overlap on this node). Errors are logged and the timer keeps going. Timers stop at node shutdown
  /// ([stopJobs]). Returns the timer (cancel to stop one job). Same contract as [Redis.runExclusive]: a lease,
  /// not a mutex — [maxRun] does not interrupt [body] (only turns `stillOwner()` false and stops the keep-alive),
  /// and a true `stillOwner()` does not guard the next write, so check it before each batch and keep the effects
  /// idempotent / conditional.
  static Timer every(String name, Duration interval, Duration ttl,
      Future<void> Function(bool Function() stillOwner) body, {Duration? maxRun}) {
    var running = false;
    final t = Timer.periodic(interval, (_) async {
      if (running) return;
      running = true;
      try {
        await Redis.runExclusive(name, ttl, body, maxRun: maxRun);
      } catch (e) {
        stderr.writeln('Ignis job $name — $e');
      } finally {
        running = false;
      }
    });
    _jobs.add(t);
    return t;
  }

  /// Cancels every [every] timer (called on shutdown before the locks are released).
  static void stopJobs() {
    for (final t in _jobs) {
      t.cancel();
    }
    _jobs.clear();
  }

  /// Why the node must not start with this `IGNIS_TRUSTED_PROXIES`, or null. Unset is refused: behind a
  /// proxy that nobody declared, every client has the proxy address — sign-in limits lock everyone out
  /// at once and the audit log records only the proxy. `none` states that there is no proxy.
  static String? trustedProxiesError(Map<String, String> env) {
    final v = (env['IGNIS_TRUSTED_PROXIES'] ?? '').trim();
    if (v.isEmpty) {
      return 'IGNIS_TRUSTED_PROXIES is not set — the node will not start. Behind a reverse proxy set it to the '
          "proxy's IPs/CIDRs (comma-separated); with clients connecting directly set IGNIS_TRUSTED_PROXIES=none.";
    }
    if (v.toLowerCase() == 'none') return null;
    if (v.split(',').any((s) => s.trim().toLowerCase() == 'none')) {
      return 'IGNIS_TRUSTED_PROXIES=$v — `none` cannot be combined with addresses.';
    }
    final errors = parseTrustedProxies(v).map(trustedProxyEntryError).whereType<String>().toList();
    if (errors.isNotEmpty) {
      return 'IGNIS_TRUSTED_PROXIES=$v — ${errors.join('; ')}. The node will not start: use IPs or CIDRs of the '
          'proxies (e.g. 10.0.0.5,10.1.0.0/16) or none.';
    }
    return null;
  }

  /// Warnings for backends reached outside loopback with TLS off: credentials and data cross the network
  /// in plaintext unless the network itself is trusted.
  static List<String> backendTlsWarnings(Map<String, String> env) {
    String warn(String what, String host, String fix) =>
        'Ignis WARNING: $what at $host is outside loopback and TLS is off — set $fix, unless the network is private and trusted.';
    return [
      if (_remote(env['IGNIS_DB_HOST']) && (env['IGNIS_DB_SSL'] ?? 'disable') == 'disable')
        warn('PostgreSQL', env['IGNIS_DB_HOST']!, 'IGNIS_DB_SSL=verify-full'),
      if (_remote(env['IGNIS_DB_HOST']) && env['IGNIS_DB_SSL'] == 'require')
        'Ignis WARNING: PostgreSQL at ${env['IGNIS_DB_HOST']} uses IGNIS_DB_SSL=require — encrypted, but the server '
            'certificate is not verified (no protection against a man in the middle); set IGNIS_DB_SSL=verify-full.',
      if (_remote(env['IGNIS_REDIS_HOST']) && env['IGNIS_REDIS_TLS'] != '1')
        warn('Redis', env['IGNIS_REDIS_HOST']!, 'IGNIS_REDIS_TLS=1'),
      if (_remote(env['IGNIS_S3_HOST']) && env['IGNIS_S3_SSL'] != '1') warn('S3', env['IGNIS_S3_HOST']!, 'IGNIS_S3_SSL=1'),
    ];
  }

  static bool _remote(String? host) {
    if (host == null || host.isEmpty || host == 'localhost' || host.startsWith('/')) return false;
    return !(InternetAddress.tryParse(host)?.isLoopback ?? false);
  }

  /// Warnings for a multi-node deployment: locks are released by node name, and a remote Redis holds the sessions.
  static List<String> nodeWarnings(Map<String, String> env) => [
        if ((env['IGNIS_NODE'] ?? '').isEmpty)
          'Ignis WARNING: IGNIS_NODE is not set — multi-node deployments need a unique IGNIS_NODE per node '
              '(locks are released by node name).',
        if (_remote(env['IGNIS_REDIS_HOST']) && (env['IGNIS_REDIS_PASS'] ?? '').isEmpty)
          'Ignis WARNING: Redis at ${env['IGNIS_REDIS_HOST']} is outside loopback and IGNIS_REDIS_PASS is empty — '
              'anyone on the network can read sessions; set a password.',
      ];

  /// The registry the node runs on: the Ignis core registry merged with the app's generated [app]
  /// (`Ignis.start(registry:)`). Missing → [StateError] ([noRegistryError]): a library cannot import the app's
  /// files, so the generated registry is how the app's pages and entities reach the engine.
  ///
  /// In JIT the app's [Fingerprint] is checked against the current lib/ sources, and a stale
  /// lib/ignis_registry.g.dart (a class added/changed after the last build) stops the start with a [StateError]
  /// ([buildCommand] / [watchCommand]); with `IGNIS_ALLOW_STALE_REGISTRY=1` in [env] it is ONE warning and the node
  /// runs on what it has. AOT has no sources — check skipped.
  static IgnisRegistry resolveRegistry(IgnisRegistry? app,
      {void Function(String) warn = _warn, Map<String, String>? env}) {
    if (app == null) throw StateError(noRegistryError);
    final stale = staleRegistryWarning(app.fingerprint);
    if (stale != null) {
      if ((env ?? Platform.environment)['IGNIS_ALLOW_STALE_REGISTRY'] != '1') {
        throw StateError(stale.replaceFirst('the node runs on the registry as generated', 'start refused '
            '(IGNIS_ALLOW_STALE_REGISTRY=1 runs on it anyway)'));
      }
      warn(stale);
    }
    return core.ignisRegistry.merge(app);
  }

  static void _warn(String line) => stdout.writeln(line);

  /// Node startup — the same under `dart run` and in a `dart compile exe` binary.
  ///
  /// [registry] — required: the app's `ignisRegistry` from `lib/ignis_registry.g.dart`, written by
  /// `dart run build_runner build` (or `watch`) with only `build_runner` in `dev_dependencies`; the core pages
  /// and entities are merged into it. Without it the node stops with a [StateError] ([noRegistryError]) listing
  /// those steps; a stale one stops the start under `dart run` — see [resolveRegistry].
  /// [templates] — app template directories (they win over the package).
  /// [appAssets] — app static directories under `/assets/`, searched before `IGNIS_ASSETS`.
  /// [extraCsp] — sources added to the base Content-Security-Policy per directive ([Engine.buildCsp]).
  static Future<void> start(
      {IgnisRegistry? registry,
      List<String> templates = const [],
      List<(String, String)> permissions = const [],
      List<Section> settingsSections = const [],
      Future<void> Function()? seed,
      List<void Function()> tasks = const [],
      List<String> appAssets = const [],
      String brand = 'Ignis',
      List<String> languages = const [],
      Map<String, String> redirects = const {},
      List<Mount> mounts = const [],
      String? homePage,
      String? errorBackUrl,
      Map<String, List<String>> extraCsp = const {},
      String i18n = 'i18n'}) async {
    Engine.csp = Engine.buildCsp(extraCsp);
    Ignis.permissions = permissions;
    Ignis.settingsSections = settingsSections;
    Ignis.mounts = mounts;
    Ignis.errorBackUrl = errorBackUrl ?? homePage ?? '/admin';
    Ignis.brand = brand;
    Ignis.redirects = redirects;
    Ignis.homePage = homePage;
    final env = Platform.environment;
    final port = int.parse(env['IGNIS_PORT'] ?? '8080');
    final node = env['IGNIS_NODE'] ?? 'node';
    Renderer.paths = [...templates, Renderer.packageTemplates];
    // [languages] — the first is the default; the app's `[i18n]/<language>.json` files.
    if (languages.isNotEmpty) I18n.load(i18n, languages);
    if (!Crypto.available) {
      throw StateError('No IGNIS_KEY (64 random hex chars — e.g. openssl rand -hex 32) — the node will not start, because '
          'secrets in settings would reach the database as plain text');
    }
    Engine.maxInFlight = Engine.parseMaxInFlight(env['IGNIS_MAX_INFLIGHT']);
    Engine.apiBodyBudget = Engine.parseApiBodyBudget(env['IGNIS_API_BODY_BUDGET_MB']);
    final envInt = Engine.parseEnvInt;
    Engine.multipartBudget = envInt('IGNIS_UPLOAD_BUDGET_MB', env['IGNIS_UPLOAD_BUDGET_MB'], 64) * 1024 * 1024;
    Engine.requestDeadline = Duration(seconds: envInt('IGNIS_TIMEOUT_S', env['IGNIS_TIMEOUT_S'], 120));
    Engine.shortDeadline = Duration(seconds: envInt('IGNIS_SHORT_TIMEOUT_S', env['IGNIS_SHORT_TIMEOUT_S'], 15));
    Db.bcryptWorkers = envInt('IGNIS_BCRYPT_THREADS', env['IGNIS_BCRYPT_THREADS'], Platform.numberOfProcessors);
    Storage.transferDeadline = Duration(seconds: envInt('IGNIS_S3_TIMEOUT_S', env['IGNIS_S3_TIMEOUT_S'], 60));
    final proxiesError = trustedProxiesError(env);
    if (proxiesError != null) throw StateError(proxiesError);
    backendTlsWarnings(env).forEach(stdout.writeln);
    nodeWarnings(env).forEach(stdout.writeln);
    if (Crypto.previousKeyInvalid) {
      throw StateError('IGNIS_KEY_PREVIOUS is set but is not a valid key (64 random hex chars) — the node will not start, '
          'because secrets not yet re-encrypted by bin/rekey.dart would be unreadable');
    }

    // Page and entity registry (once, at startup) from the generated registry.
    final source = resolveRegistry(registry);
    PageRegistry.build(source);
    EntityRegistry.build(source);
    // `{{ obj.field }}` on page/entity objects reads through the generated getters.
    Renderer.attributeGetters = source.attributes;
    stdout.writeln('Ignis entities: ${EntityRegistry.names.join(', ')}');

    // AUTO-SCHEMA: tables and columns come from @Entity classes (IGNIS_SCHEMA=update|validate|none).
    // So a new node needs no migration file — see engine/schema.dart.
    stdout.writeln('Ignis schema (${Schema.mode(env)}):');
    // ONE start-up lock around both: another node never sees the schema without the seed
    await Schema.underStartLock(() async {
      await Schema.sync();
      await Seed.seed();
      // the app seed (indexes, data migrations) too — N nodes starting at once must not run it concurrently
      await seed?.call();
    });
    await Storage.prepare();
    // Audit log cleanup — once a day, one node at a time.
    AuditLog.start();
    for (final z in tasks) {
      z();
    }
    stdout.writeln('Ignis node "$node" — registered routes: '
        '${PageRegistry.routes.join(', ')}');

    // HTTP server: loopback only by default — bare node HTTP from the network would bypass TLS and proxy limits.
    final server = await HttpServer.bind(env['IGNIS_BIND'] ?? InternetAddress.loopbackIPv4, port);
    // an idle connection is released after 30 s (120 by default) — fewer hanging sockets
    server.idleTimeout = const Duration(seconds: 30);
    stdout.writeln('Ignis listening on ${server.address.address}:$port');
    final assets = Ignis.assetDirs = [...appAssets, env['IGNIS_ASSETS'] ?? 'web/assets', Renderer.packageAssets];
    final shutdown = Shutdown();
    var closingNow = false;
    Future<void> finish(ProcessSignal s) async {
      if (closingNow) return;
      closingNow = true;
      stdout.writeln('Ignis: $s — finishing ${shutdown.inFlight} requests (20 s limit)');
      final clean = await shutdown.close(server);
      if (!clean) stderr.writeln('Ignis: requests aborted after 20 s');
      stopJobs();
      // running bodies see stillOwner() false and get a moment to stop; locks of runs still going are kept
      // (TTL frees them), or another node would run the same job alongside
      final stillRunning = await Redis.abandonExclusive();
      try {
        await Redis.releaseLocks(Redis.lockNode, keep: stillRunning);
      } catch (e) {
        stderr.writeln('Ignis: releasing locks — $e');
      }
      try {
        await Db.close();
      } catch (e) {
        stderr.writeln('Ignis: closing the pool — $e');
      }
      exit(0);
    }

    ProcessSignal.sigterm.watch().listen(finish);
    ProcessSignal.sigint.watch().listen(finish);
    await for (final req in server) {
      shutdown.track(Engine.guarded(req, () => dispatch(req, assets)));
    }
  }
}

/// The node's request dispatcher (what [Ignis.start] calls for every request).
Future<void> dispatch(HttpRequest req, List<String> assets) async {
  if (req.uri.path == '/' && Ignis.homePage != null) {
    req.response
      ..statusCode = HttpStatus.found
      ..headers.set(HttpHeaders.locationHeader, Ignis.homePage!);
    return req.response.close();
  }
  // moved addresses (bookmarks, links in e-mails) — 301 with the same query
  if (Ignis.redirects[req.uri.path] case final target?) {
    req.response
      ..statusCode = HttpStatus.movedPermanently
      // path + query only: `GET //evil.example/old` or absolute-form does not carry the host into Location
      ..headers.set(HttpHeaders.locationHeader, Uri(path: target, query: req.uri.hasQuery ? req.uri.query : null).toString());
    return req.response.close();
  }
  // /files/YYYY/MM/key.ext → the /files route with the key in a parameter.
  // A path instead of a query string, because that is how it looks in page content and in a CDN cache.
  if (req.uri.path.startsWith('/files/')) {
    final key = req.uri.path.substring('/files/'.length);
    return Engine.handle(req,
        overridePath: '/files', extraParams: {'k': key});
  }
  // theme static files are served before the engine — they are not pages
  if (req.uri.path.startsWith('/assets/')) return _staticFile(req, assets);
  for (final m in Ignis.mounts) {
    if (req.uri.path.startsWith(m.prefix)) return serveMount(req, m);
  }
  // every request goes through the full page lifecycle
  return Engine.handle(req);
}

/// Asset file from the first directory where it exists (app before library).
/// Null when missing or when the path leaves the directory.
File? assetFile(List<String> dirs, String relative) {
  if (relative.contains('..')) return null;
  for (final k in dirs) {
    final f = File('$k/$relative');
    if (f.existsSync()) return f;
  }
  return null;
}

/// Computed asset versions (until the process restarts).
final assetVersions = <String, String?>{};
final _assetLink = RegExp(r'''((?:href|src)=")(/assets/([^"?#]+))"''');

/// Appends `?v=<md5 of content, 10 hex>` to every `href|src="/assets/…"` in [html]
/// when the file exists in [dirs]. The hash is computed once per file per process.
String versionAssets(String html, List<String> dirs) {
  final prefix = dirs.join('|');
  return html.replaceAllMapped(_assetLink, (m) {
    final v = assetVersions.putIfAbsent('$prefix|${m[3]}', () {
      final f = assetFile(dirs, Uri.decodeComponent(m[3]!));
      return f == null ? null : md5.convert(f.readAsBytesSync()).toString().substring(0, 10);
    });
    return v == null ? m[0]! : '${m[1]}${m[2]}?v=$v"';
  });
}

/// A second spelling of a file path (`//`, leading or trailing `/`, `\`): each one would get its own entry in
/// [assetVersions] / [_gzipped], so an attacker could grow them without bound.
bool _aliasPath(String relative) =>
    relative.contains('\\') || relative.isNotEmpty && relative.split('/').any((s) => s.isEmpty);

/// Serves theme files from the asset directories. Outside the route registry — a file is not a page.
Future<void> _staticFile(HttpRequest req, List<String> dirs) async {
  final res = req.response;
  try {
    // protection against leaving the directory (../../etc/passwd)
    final relative = Uri.decodeComponent(req.uri.path.substring('/assets/'.length));
    if (relative.contains('..') || _aliasPath(relative)) {
      res.statusCode = HttpStatus.badRequest;
      await res.close();
      return;
    }
    File? f;
    for (final k in dirs) {
      final p = File('$k/$relative');
      if (await p.exists()) {
        f = p;
        break;
      }
    }
    if (f == null) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    final mime = assetMime(relative);
    // the same digest as in ?v= — computed once per file per process, then 304 without reading the file
    final key = '${dirs.join('|')}|$relative';
    final version = assetVersions[key] ??= (await md5.bind(f.openRead()).first).toString().substring(0, 10);
    final etag = 'W/"$version"';
    if (mime.startsWith('text/html')) res.headers.set('Content-Security-Policy', Engine.csp);
    res.headers
      ..contentType = ContentType.parse(mime)
      // immutable only for THIS content's ?v= ([versionAssets]): in a rolling deploy an old node asked for the
      // new version must not pin the old file under the new URL
      ..set(HttpHeaders.cacheControlHeader,
          req.uri.queryParameters['v'] == version ? 'public, max-age=31536000, immutable' : 'no-cache');
    await _sendFile(req, f, mime, etag, key);
  } catch (_) {
    res.statusCode = HttpStatus.internalServerError;
  }
  await res.close();
}

/// Gzipped text static files: path → (ETag, gzip). One entry per file — a new ETag replaces it;
/// files over [_maxGzipInMemory] are gzipped as a stream, so a large build does not sit in RAM.
final _gzipped = <String, (String, List<int>)>{};
const _maxGzipInMemory = 1024 * 1024;

/// 304 on If-None-Match, gzip for text (from memory, not on every request), otherwise raw bytes.
/// Static files only: pages with a CSRF token and echoed input would be open to BREACH once compressed.
Future<void> _sendFile(HttpRequest req, File f, String mime, String etag, String key) async {
  final res = req.response;
  res.headers
    ..set(HttpHeaders.etagHeader, etag)
    ..set(HttpHeaders.varyHeader, 'Accept-Encoding');
  if (req.headers.value(HttpHeaders.ifNoneMatchHeader) == etag) {
    res.statusCode = HttpStatus.notModified;
    return;
  }
  final gz = _isText(mime) &&
      (req.headers.value(HttpHeaders.acceptEncodingHeader) ?? '').split(',').any((e) => e.trim().startsWith('gzip'));
  if (gz) res.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
  if (req.method == 'HEAD') return;
  if (!gz) return res.addStream(f.openRead());
  final w = _gzipped[key];
  if (w != null && w.$1 == etag) return res.add(w.$2);
  if (await f.length() > _maxGzipInMemory) return res.addStream(f.openRead().transform(gzip.encoder));
  final b = gzip.encode(await f.readAsBytes());
  _gzipped[key] = (etag, b);
  res.add(b);
}

bool _isText(String mime) =>
    mime.startsWith('text/') || mime.startsWith('application/javascript') || mime.startsWith('application/json') ||
    mime == 'image/svg+xml' || mime == 'application/wasm';

/// Directory of public files under a URL prefix, e.g. `Mount('/sdk/', 'web/sdk')`: `/sdk/x.js` → `web/sdk/x.js`.
/// For files loaded from other sites (SDK script, service worker for `importScripts`), hence
/// `Access-Control-Allow-Origin: *` (the files are public, no cookies). [immutable] says which (relative)
/// paths never change content — e.g. a versioned directory — and get a one-year cache; the rest
/// [maxAge] seconds, so a fix to an unversioned URL arrives quickly.
class Mount {
  final String prefix;
  final String catalog;
  final int maxAge;
  final bool Function(String relative)? immutable;
  const Mount(this.prefix, this.catalog, {this.maxAge = 300, this.immutable});
}

/// Serves a file from [m] (GET/HEAD); 404 when missing or when the path leaves the directory.
Future<void> serveMount(HttpRequest req, Mount m) async {
  final res = req.response;
  try {
    final relative = Uri.decodeComponent(req.uri.path.substring(m.prefix.length));
    if (_aliasPath(relative)) {
      res.statusCode = HttpStatus.badRequest;
      await res.close();
      return;
    }
    final f = File('${m.catalog}/$relative');
    final st = req.method == 'GET' || req.method == 'HEAD' ? await f.stat() : null;
    if (st == null) {
      res.statusCode = HttpStatus.methodNotAllowed;
    } else if (relative.isEmpty || relative.contains('..') ||
        st.type != FileSystemEntityType.file) {
      res.statusCode = HttpStatus.notFound;
    } else {
      final mime = assetMime(relative);
      res.headers
        ..contentType = ContentType.parse(mime)
        ..set('Access-Control-Allow-Origin', '*')
        ..set('X-Content-Type-Options', 'nosniff')
        ..set(HttpHeaders.cacheControlHeader,
            m.immutable?.call(relative) == true ? 'public, max-age=31536000, immutable' : 'public, max-age=${m.maxAge}');
      // ETag from size and modification time: a replaced file at an unversioned URL arrives without a restart
      final etag = 'W/"${st.size.toRadixString(36)}-${st.modified.microsecondsSinceEpoch.toRadixString(36)}"';
      await _sendFile(req, f, mime, etag, '${m.prefix}|$relative');
    }
  } catch (_) {
    res.statusCode = HttpStatus.internalServerError;
  }
  await res.close();
}

/// Content type of an asset by extension (also a Flutter web build: html, mjs, wasm — CanvasKit requires application/wasm).
String assetMime(String p) => switch (p.split('.').last.toLowerCase()) {
      'css' => 'text/css',
      'js' || 'mjs' => 'application/javascript',
      'html' || 'htm' => 'text/html; charset=utf-8',
      'wasm' => 'application/wasm',
      'webp' => 'image/webp',
      'otf' => 'font/otf',
      'txt' => 'text/plain; charset=utf-8',
      'json' => 'application/json',
      'svg' => 'image/svg+xml',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'ico' => 'image/x-icon',
      'woff' => 'font/woff',
      'woff2' => 'font/woff2',
      'ttf' => 'font/ttf',
      'eot' => 'application/vnd.ms-fontobject',
      _ => 'application/octet-stream',
    };
