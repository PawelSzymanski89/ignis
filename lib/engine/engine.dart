// ============================================================================
//  engine.dart — request dispatcher + page lifecycle loop
// ----------------------------------------------------------------------------
//  Everything comes together here: take the HttpRequest, parse it (query+form+cookies),
//  look the route up in PageRegistry, create the page instance, call the lifecycle
//  methods in EXACTLY the fixed order and build the response.
//
//  Order (see PageEngine):
//    1. doBeforeProcess() : bool  — false ⇒ return the output stream, no render
//    2. isAbleToSee()      : bool  — false ⇒ redirect to meta.redirectIfNotAbleToSee
//    3. processData()      : bool  — false ⇒ return the output stream, no render
//    4. insertData()       : void  — put(...) into the model; template render HERE
//    5. doAfterProcess()   : void  — hook after render
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'ignis.dart';
import 'client_ip.dart';
import 'db.dart';
import 'audit_log.dart';
import 'page_engine.dart';
import 'redis.dart';
import 'admin_page.dart';
import 'annotations.dart';
import 'registry.dart';
import 'tenant.dart';
import 'i18n.dart';
import 'render.dart';
import 'upload.dart';
import 'session.dart';
import 'customer_accounts.dart';

part 'engine_cors.dart';
part 'engine_headers.dart';
part 'engine_language.dart';

/// API request body as text. When [gzipped], inflates it while counting the
/// size: a zip bomb stops at [limit] before it reaches memory.
/// Throws [UploadTooLarge] when over the limit, [FormatException] on broken gzip.
String readBody(List<int> bytes, bool gzipped, {int limit = 8 * 1024 * 1024, void Function(int)? reserve}) =>
    utf8.decode(readBytes(bytes, gzipped, limit: limit, reserve: reserve), allowMalformed: true);

/// Like [readBody], but without decoding text (binary body, `@Page(binary: true)`).
/// [reserve] is called with every inflated chunk before it is kept (the node's API body budget).
List<int> readBytes(List<int> bytes, bool gzipped, {int limit = 8 * 1024 * 1024, void Function(int)? reserve}) {
  if (!gzipped) return bytes;
  final result = BytesBuilder(copy: false);
  final input = gzip.decoder.startChunkedConversion(_LimitedSink(result, limit, reserve));
  input
    ..add(bytes)
    ..close();
  return result.takeBytes();
}

class _LimitedSink implements Sink<List<int>> {
  _LimitedSink(this.result, this.limit, this.reserve);
  final BytesBuilder result;
  final int limit;
  final void Function(int)? reserve;
  @override
  void add(List<int> k) {
    if (result.length + k.length > limit) throw UploadTooLarge(limit);
    reserve?.call(k.length);
    result.add(k);
  }

  @override
  void close() {}
}

class Engine {
  /// CSRF cookie — with the `__Host-` prefix (see the comment at the check).
  static const csrfCookie = '__Host-ignis_csrf';
  static final _rng = Random.secure();
  static String _token() => List.generate(24, (_) => _rng.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  /// Handles a request in a zone that also catches errors from un-awaited Futures —
  /// an unhandled exception ends this one request (500), not the whole process.
  /// Also writes one log line per request and an id in `X-Request-Id`.
  static Future<void> guarded(HttpRequest req, Future<void> Function() handler) {
    if (_inFlight >= maxInFlight) return _overloaded(req);
    _inFlight++;
    final end = Completer<void>();
    final id = List.generate(8, (_) => _rng.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final elapsed = Stopwatch()..start();
    req.response.headers.set('X-Request-Id', id);
    securityHeaders(req.response.headers);
    // a slow client (body, or reading the response byte by byte) does not hold the socket forever — after
    // the deadline dart:io drops the connection and reading the body fails
    req.response.deadline = requestDeadline;
    Future<void> error(Object e, StackTrace st) async {
      stderr.writeln('Ignis 500 id=$id: $e\n$st');
      try {
        await errorPage(req.response, HttpStatus.internalServerError, 'server', language: requestLanguage(req));
      } catch (_) {
        await req.response.close().catchError((_) {}); // the error page did not go out — close the response anyway
      }
    }
    runZonedGuarded(() async {
      try {
        // broken %-encoding (`?q=%ff`) throws on every parameter read — once here, 400 instead of 500
        try {
          req.uri.queryParameters;
        } on FormatException {
          await errorPage(req.response, HttpStatus.badRequest, 'bad_data', language: requestLanguage(req));
          end.complete();
          return;
        }
        await handler();
      } catch (e, st) {
        await error(e, st);
      }
      end.complete();
    }, error, zoneValues: {#ignisRequestId: id});
    return end.future.whenComplete(() {
      _inFlight--;
      // the deadline timer does not stop on close() — on keep-alive it would kill the next request
      req.response.deadline = null;
      stdout.writeln(logLine(req.method, req.uri.path, req.response.statusCode, elapsed.elapsedMilliseconds, id));
    });
  }

  /// Requests handled at once (`IGNIS_MAX_INFLIGHT`, 512 by default); above it 503 with `Retry-After`
  /// before routing, so a flood does not queue bodies, pool waits and bcrypt jobs without bound.
  /// [Ignis.start] sets it from [parseMaxInFlight].
  static int maxInFlight = 512;

  /// Integer variable [key]: unset or blank → [def]; anything but an integer ≥ [min] (after trim) stops the node.
  static int parseEnvInt(String key, String? raw, int def, {int min = 1}) {
    final t = raw?.trim();
    if (t == null || t.isEmpty) return def;
    final n = int.tryParse(t);
    if (n == null || n < min) throw StateError('$key=$raw — must be an integer ≥ $min ($def by default)');
    return n;
  }
  static int _inFlight = 0;

  /// `IGNIS_MAX_INFLIGHT`: unset → 512; anything but an integer ≥ 1 stops the node (0 would answer 503 to everything).
  static int parseMaxInFlight(String? value) {
    if (value == null) return 512;
    final n = int.tryParse(value.trim());
    if (n == null || n < 1) throw StateError('IGNIS_MAX_INFLIGHT=$value — must be an integer ≥ 1 (512 by default)');
    return n;
  }

  static final _rejectLog = Stopwatch();
  static int _rejectsUnlogged = 0;

  static Future<void> _overloaded(HttpRequest req) async {
    final res = req.response;
    final id = List.generate(8, (_) => _rng.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    res.headers.set('X-Request-Id', id);
    res.headers.set(HttpHeaders.retryAfterHeader, '5');
    securityHeaders(res.headers);
    try {
      if (PageRegistry.underApi(req.uri.path)) return await apiError(res, HttpStatus.serviceUnavailable);
      await errorPage(res, HttpStatus.serviceUnavailable, 'other', language: requestLanguage(req));
    } catch (_) {
      await res.close().catchError((_) {});
    } finally {
      // at most one line a second under a flood; the next line says how many were not logged
      if (_rejectLog.isRunning && _rejectLog.elapsedMilliseconds < 1000) {
        _rejectsUnlogged++;
      } else {
        final more = _rejectsUnlogged > 0 ? ' (+$_rejectsUnlogged more 503 not logged)' : '';
        _rejectsUnlogged = 0;
        _rejectLog
          ..reset()
          ..start();
        stdout.writeln('${logLine(req.method, req.uri.path, HttpStatus.serviceUnavailable, 0, id)} overloaded$more');
      }
    }
  }

  /// Total `Content-Length` of multiparts buffered at once (`IGNIS_UPLOAD_BUDGET_MB`, 64 MB by default);
  /// above it an upload gets 503 instead of another 16 MB in RAM.
  /// [Ignis.start] sets it from [parseEnvInt], so a bad value stops the node.
  static int multipartBudget = 64 * 1024 * 1024;
  static int _multipartInFlight = 0;

  /// Total bytes of `api: true` bodies held at once (`IGNIS_API_BODY_BUDGET_MB`, 64 MB by default), on the wire and
  /// after gzip inflation, reserved as they arrive; above it 503 with `Retry-After`.
  /// [Ignis.start] reads it at start-up, so a bad value stops the node.
  static int apiBodyBudget = parseApiBodyBudget(Platform.environment['IGNIS_API_BODY_BUDGET_MB']);

  /// `IGNIS_API_BODY_BUDGET_MB` in bytes: unset → 64 MB; anything but an integer ≥ 1 stops the node.
  static int parseApiBodyBudget(String? value) {
    if (value == null) return 64 * 1024 * 1024;
    final n = int.tryParse(value.trim());
    if (n == null || n < 1) throw StateError('IGNIS_API_BODY_BUDGET_MB=$value — must be an integer ≥ 1 (64 by default)');
    return n * 1024 * 1024;
  }
  static int _apiBodyInFlight = 0;

  /// Most fields in an x-www-form-urlencoded form (like [Upload.maxParts] for multipart).
  static const maxFormFields = 1000;

  /// Total request time limit (`IGNIS_TIMEOUT_S`, 120 s by default — with room for a 16 MB upload).
  /// Applies until the route is matched and for routes with `maxBody`.
  /// [Ignis.start] sets it from [parseEnvInt], so a bad value stops the node.
  static Duration requestDeadline = const Duration(seconds: 120);

  /// Limit for routes without `maxBody` (`IGNIS_SHORT_TIMEOUT_S`, 15 s by default): a plain form does not
  /// need two minutes, and a slow client should not hold the socket as long as an upload.
  /// [Ignis.start] sets it from [Engine.parseEnvInt], so a bad value stops the node.
  static Duration shortDeadline = const Duration(seconds: 15);

  static Duration routeDeadline(Page? meta) =>
      meta?.maxBody == null && shortDeadline < requestDeadline ? shortDeadline : requestDeadline;

  /// Headers of every node response (pages, static files, errors) — without relying on proxy config.
  /// SAMEORIGIN, not DENY: the panel embeds its own previews in iframes.
  /// HSTS only on request (`IGNIS_HSTS=1`). Implementation: engine_headers.dart.
  static void securityHeaders(HttpHeaders h) => _securityHeaders(h);

  /// CSP of every HTML response (pages, errors, static .html) — the `<meta>` in layouts stays as a
  /// fallback, but it does not cover `frame-ancestors` or pages on their own layouts.
  /// Set once at startup from [Ignis.start]'s `extraCsp` (see [buildCsp]).
  static String csp = buildCsp(const {});

  /// The same policy for the layouts' `<meta>` — a meta CSP ignores `frame-ancestors`.
  static String get cspMeta => csp.replaceFirst(RegExp(r"; frame-ancestors [^;]*$"), '');

  /// The base policy plus [extra] sources per directive (e.g. `{'img-src': ['https://cdn.example.com']}`).
  /// Throws [ArgumentError] on an unknown directive, a malformed source, `'none'`, or
  /// `'unsafe-inline'`/`'unsafe-eval'` in a `script-src*` directive (`'wasm-unsafe-eval'` is allowed).
  static String buildCsp(Map<String, List<String>> extra) => _buildCsp(extra);

  /// Id of the current request (from `guarded`), or null outside a request.
  static String? get requestId => Zone.current[#ignisRequestId] as String?;

  /// Request log line: no query, body, headers or cookies.
  static String logLine(String method, String path, int code, int ms, String id) =>
      'Ignis $method $path $code ${ms}ms id=$id';

  /// Handles one HTTP request from start until the response is written.
  /// Each step returns false when it has already written the response (error, redirect, preflight).
  /// The order of the steps is the order of the security checks — do not reorder.
  static Future<void> handle(HttpRequest req,
      {String? overridePath, Map<String, String>? extraParams}) async {
    final r = _Request(req, overridePath ?? req.uri.path);
    try {
      if (!await _resolveRoute(r)) return;
      if (!await _resolveTenant(r)) return;
      if (!await _preflightAndMethod(r)) return;
      if (!await _readInput(r, extraParams)) return;
      if (!await _checkCsrf(r)) return;
      final ready = await _runPage(r);
      // transaction committed and connection back in the pool — only now we write to the client
      await _flush(r.res, ready);
    } on Overloaded {
      // full bcrypt queue — the client should retry in a moment, this is not a failure
      try {
        r.res.headers.set(HttpHeaders.retryAfterHeader, '5');
      } catch (_) {}
      if (PageRegistry.underApi(r.path)) {
        return apiError(r.res, HttpStatus.serviceUnavailable);
      }
      await errorPage(r.res, HttpStatus.serviceUnavailable, 'other', language: requestLanguage(req));
    } catch (e, st) {
      // Stack ONLY to the server log; the client gets a generic error (no leak).
      // Details ONLY to the server log — the client must not see the stack trace.
      stderr.writeln('Ignis 500 id=$requestId: $e\n$st');
      try {
        await r.errorEntry?.call();
      } catch (e) {
        stderr.writeln('Ignis audit log: error entry not saved: $e');
      }
      if (PageRegistry.underApi(r.path)) {
        return apiError(r.res, HttpStatus.internalServerError);
      }
      await errorPage(r.res, HttpStatus.internalServerError, 'server', language: requestLanguage(req));
    } finally {
      _apiBodyInFlight -= r.apiBytes;
    }
  }

  /// Route lookup, its deadline and the error format (HTML page or API JSON).
  static Future<bool> _resolveRoute(_Request r) async {
    r.route = PageRegistry.match(r.path);
    r.api = PageRegistry.underApi(r.path);
    // the deadline is set by [guarded]; outside it (null) no timer that would outlive the request
    if (r.res.deadline != null) r.res.deadline = routeDeadline(r.route?.meta);
    // the API client is an SDK, not a browser — JSON {"error": …}, no HTML page
    r.language = requestLanguage(r.req);
    // unknown path under the API prefix — 404 without asking the database for the tenant
    if (r.api && r.route == null) {
      await apiError(r.res, HttpStatus.notFound);
      return false;
    }
    return true;
  }

  /// Service from the domain, the panel-domain redirect and 404 for an unknown route.
  static Future<bool> _resolveTenant(_Request r) async {
    final req = r.req, res = r.res, route = r.route;
    // Service from the domain. An unknown domain does NOT get a default tenant —
    // guessing here would mean showing someone another tenant's data.
    // Technical routes (health probe) are skipped: they are called by IP, without a domain.
    if (route?.meta.technical ?? false) {
      // The probe answers only loopback and a trusted proxy (by socket address, not by Host) —
      // everyone else does not learn the state of the database, Redis or the node name.
      if (!probeAllowed(req.connectionInfo?.remoteAddress.address ?? '',
          req.headers.value('X-Forwarded-For'), trustedProxies)) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return false;
      }
      r.context = TenantContext.platformContext;
    } else {
      final k = await Tenants.fromHost(req.headers.host);
      if (k == null) {
        await r.error(HttpStatus.notFound, 'unknown_domain');
        return false;
      }
      if (!k.active) {
        await r.error(HttpStatus.paymentRequired, 'inactive', detail: k.reason);
        return false;
      }
      r.context = k;
    }

    // The panel lives under `admin.<domain>`, the front under the bare domain. Entering
    // /admin from the front side ended in a loop: sign-in succeeded,
    // and the first panel page sent the user back to sign-in, because the
    // "this is not the panel" barrier has no way to explain itself. We redirect to where
    // the panel actually is.
    if (!r.context.panel && r.path.startsWith('/admin')) {
      final target = 'https://admin.${r.context.domain}${r.path}';
      res.statusCode = HttpStatus.movedTemporarily;
      res.headers.set(HttpHeaders.locationHeader, target);
      await res.close();
      return false;
    }

    // No route → 404 in the panel theme.
    if (route == null) {
      await r.error(HttpStatus.notFound, 'not_found');
      return false;
    }
    return true;
  }

  /// CORS preflight of a `cors: true` route, then `@Page(methods:)`.
  static Future<bool> _preflightAndMethod(_Request r) async {
    final req = r.req, res = r.res, meta = r.route!.meta;
    if (meta.cors && req.method == 'OPTIONS') {
      await preflightWithGate(res.headers, meta, req.headers.value('origin'),
          req.headers.value('access-control-request-headers'), req.uri);
      res.statusCode = HttpStatus.noContent;
      await res.close();
      return false;
    }
    if (!methodAllowed(meta, req.method)) {
      res.headers.set(HttpHeaders.allowHeader, meta.methods.join(', '));
      await r.error(HttpStatus.methodNotAllowed, 'method', detail: req.method);
      return false;
    }
    return true;
  }

  /// Parameters (query + form), cookies, client address and the body, with their limits.
  static Future<bool> _readInput(_Request r, Map<String, String>? extraParams) async {
    final req = r.req, route = r.route!;
    // CSRF, body and the token cookie — from THIS route's declaration. `api` (path prefix) only picks the
    // error format: a page `/admin/api/x` with `api: true` cannot lift CSRF off the whole `/admin/`.
    r.apiRoute = route.meta.api;
    // methods that by definition do not change state — only they go without a CSRF token
    r.safe = const {'GET', 'HEAD', 'OPTIONS'}.contains(req.method);

    // Collect the input: parameters (query+form) and cookies.
    req.uri.queryParameters.forEach((k, v) => r.params[k] = v);
    extraParams?.forEach((k, v) => r.params[k] = v);
    // Client address for attempt limits — XFF only from a trusted proxy (client_ip.dart).
    r.ip = clientAddress(req.connectionInfo?.remoteAddress.address ?? 'unknown',
        req.headers.value('X-Forwarded-For'), trustedProxies);

    // cookies BEFORE the body: an upload without the CSRF / session cookie is rejected without reading 16 MB (FIX-3)
    // API routes skip CSRF, so they never see the credentials a browser attaches on its own
    for (final c in req.cookies) {
      if (r.apiRoute && (c.name == Sessions.cookieName || c.name == CustomerAccounts.cookie || c.name == csrfCookie)) {
        continue;
      }
      r.cookies[c.name] = c.value;
    }

    final read = r.apiRoute
        ? await _readApiBody(r)
        : req.method == 'POST' && Upload.isMultipart(req)
            ? await _readMultipart(r)
            : !r.safe
                ? await _readForm(r)
                : true;
    if (!read) return false;
    // AFTER parsing the body — a `__ip` form field used to override the address and reset per-IP limits.
    r.params['__ip'] = r.ip;
    return true;
  }

  /// API (SDK): raw body without form or CSRF; 2 MB on the wire (or the route's maxBody), counted incrementally.
  static Future<bool> _readApiBody(_Request r) async {
    final req = r.req, route = r.route!;
    if (!const {'POST', 'PUT', 'PATCH'}.contains(req.method)) return true;
    final max = route.meta.maxBody;
    final limit = max ?? 2 * 1024 * 1024;
    final buffer = BytesBuilder(copy: false);
    var tooLarge = false;
    await for (final k in req) {
      if (buffer.length + k.length > limit) {
        tooLarge = true;
        break;
      }
      r.reserve(k.length);
      buffer.add(k);
    }
    if (tooLarge) {
      await apiError(r.res, HttpStatus.requestEntityTooLarge);
      return false;
    }
    final gzipped = (req.headers.value(HttpHeaders.contentEncodingHeader) ?? '').trim().toLowerCase() == 'gzip';
    try {
      final inflateLimit = max ?? 8 * 1024 * 1024;
      if (route.meta.binary) {
        r.bodyBytes = readBytes(buffer.takeBytes(), gzipped, limit: inflateLimit, reserve: r.reserve);
      } else {
        r.body = readBody(buffer.takeBytes(), gzipped, limit: inflateLimit, reserve: r.reserve);
      }
    } on UploadTooLarge {
      await apiError(r.res, HttpStatus.requestEntityTooLarge);
      return false;
    } on FormatException {
      await apiError(r.res, HttpStatus.badRequest);
      return false;
    }
    return true;
  }

  /// Upload (multipart/form-data) — dart:io does not parse it, Upload does.
  /// Must run BEFORE the CSRF check, because the token arrives as a form field.
  /// Only routes that declared `maxBody`: the rest (sign-in included) does not
  /// accept files, and 16 MB in RAM before CSRF and auth is a free DoS (SEC-B-1).
  static Future<bool> _readMultipart(_Request r) async {
    final req = r.req, res = r.res, route = r.route!;
    final max = route.meta.maxBody;
    // Without a known length (chunked) or over the limit — refused before reading; likewise without
    // the CSRF cookie (foreign form) and, on panel pages, without a live session.
    final length = req.contentLength;
    if (max == null || length < 0 || length > max) {
      await r.error(HttpStatus.requestEntityTooLarge, 'too_large');
      return false;
    }
    if (r.cookies[csrfCookie] == null) {
      await r.error(HttpStatus.forbidden, 'csrf');
      return false;
    }
    if (route.pageMeta.adminPage && await Sessions.get(r.cookies[Sessions.cookieName]) == null) {
      await r.error(HttpStatus.forbidden, 'forbidden');
      return false;
    }
    // budget of multipart bytes buffered at once on the node — parallel uploads will not eat the RAM
    if (_multipartInFlight + length > multipartBudget) {
      res.headers.set(HttpHeaders.retryAfterHeader, '5');
      await r.error(HttpStatus.serviceUnavailable, 'other');
      return false;
    }
    _multipartInFlight += length;
    try {
      final w = await Upload.receive(req, req.headers.contentType?.parameters['boundary'], byteLimit: max);
      r.params.addAll(w.fields);
      r.files.addAll(w.files);
    } on UploadTooLarge catch (e) {
      await r.error(HttpStatus.requestEntityTooLarge, 'file_too_large', detail: '$e');
      return false;
    } on FormatException {
      res.statusCode = HttpStatus.badRequest;
      await res.close();
      return false;
    } finally {
      _multipartInFlight -= length;
    }
    return true;
  }

  /// x-www-form-urlencoded body of a state-changing request.
  static Future<bool> _readForm(_Request r) async {
    // body size limit (anti-DoS): 256 KB, counted INCREMENTALLY — with
    // Transfer-Encoding: chunked there is no Content-Length header (-1)
    // and an "up front" check let arbitrarily large requests through.
    const limit = 256 * 1024;
    final buffer = BytesBuilder(copy: false);
    var tooLarge = false;
    await for (final k in r.req) {
      if (buffer.length + k.length > limit) {
        tooLarge = true;
        break;
      }
      buffer.add(k);
    }
    if (tooLarge) {
      await r.error(HttpStatus.requestEntityTooLarge, 'too_large');
      return false;
    }
    final body = utf8.decode(buffer.takeBytes(), allowMalformed: true);
    // x-www-form-urlencoded form → overrides the query on collision.
    // Broken encoding is a CLIENT error (400), not a server failure (500) —
    // browsers encode correctly, so it is either a bot or a hand-made request.
    try {
      if ('&'.allMatches(body).length >= maxFormFields) throw ArgumentError('too many fields');
      Uri.splitQueryString(body).forEach((k, v) => r.params[k] = v);
    } on ArgumentError {
      await r.error(HttpStatus.badRequest, 'bad_data');
      return false;
    }
    return true;
  }

  /// CSRF (double-submit): token in a cookie + hidden form field.
  /// The `__Host-` prefix makes the browser accept this cookie only
  /// without `Domain=` and only over HTTPS — so the front of a neighbouring service in the same
  /// zone (a.ignis.x / b.ignis.x) cannot plant its own token via
  /// `document.cookie = "...; Domain=ignis.x"`.
  static Future<bool> _checkCsrf(_Request r) async {
    r.newCsrf = r.cookies[csrfCookie] == null;
    r.csrf = r.cookies[csrfCookie] ?? _token();
    if (!r.safe && !r.apiRoute) {
      // POST/PUT/PATCH/DELETE must have a csrf field == the cookie (otherwise it is a foreign form).
      if (r.cookies[csrfCookie] == null || r.params['csrf'] != r.cookies[csrfCookie]) {
        await r.error(HttpStatus.forbidden, 'csrf');
        return false;
      }
    }
    return true;
  }

  /// SERVICE CONTEXT FOR RLS: from here on the rest of the request runs on ONE
  /// connection with `ignis.service` set. Postgres policies
  /// read that value, so a forgotten `WHERE service` in code stops
  /// showing other tenants' data — this is the last line of defence, not a substitute for the filter.
  /// The connection and transaction start on the FIRST query (a page without queries takes nothing),
  /// and are returned BEFORE the response is sent: a slow client (upload, file download) does not hold the pool
  /// (PERF-A-1). `noDb` pages have no context at all.
  static Future<PageEngine> _runPage(_Request r) {
    final route = r.route!;
    final process = route.meta.noDb
        ? (Future<PageEngine> Function() f) => f()
        : (Future<PageEngine> Function() f) => Db.inContext(r.context.service, f);
    return process(() async {
      final page = _newPage(r);
      // Hydrate @Synced/@SessionSynced fields from Redis — visible for the whole lifecycle.
      // Session fields only for a live session: a made-up cookie neither creates nor reads keys.
      final token = route.syncedFields.any((f) => f.isSession)
          ? await Sessions.alive(r.cookies[Sessions.cookieName])
          : null;
      final snap = await _hydrateSynced(page, route.syncedFields, token);
      if (!await _lifecycle(r, page)) return page;
      // Persist changed synced fields (after all processing, before the response).
      await _persistSynced(page, route.syncedFields, token, snap);
      return page;
    });
  }

  /// Builds a fresh page instance and injects the request.
  static PageEngine _newPage(_Request r) {
    final req = r.req, route = r.route!;
    final page = route.newInstance();
    page.bind(
      method: req.method,
      meta: route.meta,
      // {name} path segments override query/form parameters of the same name
      params: {...r.params, ...?PageRegistry.pathParams(route.meta.route, r.path)},
      cookies: r.cookies,
      context: r.context,
      files: r.files,
      remoteAddress: r.ip,
      headerValues: _headerMap(req.headers)..removeWhere((k, _) => r.apiRoute && k == 'cookie'),
      query: req.uri.queryParameters,
    );
    page.body = r.body;
    page.bodyBytes = r.bodyBytes;

    if (!r.apiRoute) {
      page.put('csrf', r.csrf); // available in templates as {{csrf}}
      if (r.newCsrf) page.setCookie(csrfCookie, r.csrf, httpOnly: true);
      pageLanguage(page, r.params['lang'], r.cookies, req.headers.value('accept-language'));
    }
    return page;
  }

  /// The page LIFECYCLE (one exit at the end). false = synced fields are not persisted
  /// (forced password change).
  static Future<bool> _lifecycle(_Request r, PageEngine page) async {
    if (!await page.doBeforeProcess()) {
      // 1) gate before auth — false ⇒ the page handled the response itself (output stream)
    } else if (!await page.isAbleToSee()) {
      // 2) authorization — false ⇒ redirect to meta.redirectIfNotAbleToSee.
      // a password set by someone else: we lead to the password change, not
      // to sign-in — sending to sign-in would look like a broken session
      if (page is AdminPage && page.restricted && page.session != null) {
        page.redirect('/admin/account');
        return false;
      }
      page.redirect(page.meta.redirectIfNotAbleToSee);
    } else if (!await page.processData()) {
      // 3) gate after auth — false ⇒ the page handled the response itself
    } else {
      // 3.5) ACTIONS before insertData; false ⇒ the action handled the response itself
      var proceed = await _triggeredAction(r, page);
      if (proceed) {
        // 4) render (only when actions did not stop it) + 5) hook after render
        await page.insertData();
      }
      // insertData may have decided there is nothing to show — notFound()/forbidden() (error page) or
      // redirect() (e.g. no id → list). Then no render: a template with an empty model would blow up
      // and 500 would go out instead of 404/302.
      // exception: a validation error from fieldError — 422 with the form to fix, not an error page
      final formError = page.fieldErrors.isNotEmpty && page.redirectTarget == null;
      if (proceed && (page.responseReady || (!formError && (page.status >= 400 || page.redirectTarget != null)))) {
        proceed = false;
      } else if (proceed) {
        page.prepareFormErrors();
        // htmx asks for the content only — it already has the panel shell (menu, topbar).
        // The same page template serves both cases, only the parent differs.
        page.put('layout', layoutFor(r.req.headers.value));
        page.write(Renderer.render(page.meta.template, page.model));
        await page.doAfterProcess();
      }
    }
    return true;
  }

  /// ACTIONS — triggerAction=<name> runs @Action(name) methods BEFORE
  /// insertData. An action returns bool: false ⇒ it handled the response itself
  /// (e.g. redirect/JSON in the output stream) → render skipped, as with the other gates.
  /// POST ONLY: the CSRF token is checked only for POST, so an action
  /// triggered from the query string (GET) would bypass it with a plain link.
  static Future<bool> _triggeredAction(_Request r, PageEngine page) async {
    final route = r.route!, params = r.params;
    final same = params['triggerAction'];
    if (r.req.method != 'POST' || same == null || !route.actions.containsKey(same)) return true;
    // TRAIL: every panel action reaches the audit log from here, not separately
    // in each page — otherwise the first new page would drop out of the audit
    // and nobody would notice until someone asks "who changed this".
    // An exception after the action rolls back the request transaction (often already aborted) with the entry — the
    // `error` entry then goes in a separate transaction after ROLLBACK (catch in handle), otherwise no trace would remain.
    if (page is AdminPage && page.login.isNotEmpty) {
      final service = r.context.service;
      Future<void> entry(String result) => AuditLog.save(
            service: service,
            actor: page.login,
            location: route.meta.route,
            action: same,
            detail: AuditLog.describe(params),
            ip: r.ip,
            result: result,
          );
      r.errorEntry = () => Db.inContext(service, () => entry('error'));
      final proceed = await runActions(page, same, route.actions[same]!);
      await entry(page.denied ? 'denied' : 'ok');
      return proceed;
    }
    return runActions(page, same, route.actions[same]!);
  }

  /// Page language for a request without a page (engine error) — the same rules as [pageLanguage].
  static String requestLanguage(HttpRequest req) => _requestLanguage(req);

  /// Error for an API client: `{"error": "<English description>"}` with [code].
static Future<void> apiError(HttpResponse res, int code) async {
  try {
    res.statusCode = code;
  } on StateError {
    await res.close().catchError((_) {});
    return;
  }
  res.headers.contentType = ContentType.json;
  res.headers.set('Cache-Control', 'no-store');
  res.write(jsonEncode({'error': errorDescription(code)}));
  await res.close();
}

/// English description of an HTTP status for API responses.
static String errorDescription(int code) => switch (code) {
      400 => 'bad request',
      401 => 'unauthorized',
      402 => 'service inactive',
      403 => 'forbidden',
      404 => 'not found',
      405 => 'method not allowed',
      410 => 'gone',
      413 => 'payload too large',
      422 => 'unprocessable entity',
      429 => 'too many requests',
      _ when code >= 500 => 'internal server error',
      _ => 'error',
    };

  /// Page language → `page.language` and in the model: `language`, `languages`, `t(key)`, `tn(key, n)` and `q_lang` — the current
  /// query without `lang` (encoded, with a leading `&`), so the switcher `?lang=xx{{ q_lang }}` does not drop e.g. `next`.
  /// A supported `?lang=` is remembered in a cookie for a year.
  static void pageLanguage(PageEngine page, String? param, Map<String, String> cookies,
          String? acceptLanguage) =>
      _pageLanguage(page, param, cookies, acceptLanguage);

  /// Preflight gate: the app says whether [origin] may call its API at all (e.g. it is on the site list
  /// of some project). Refusal = 204 without CORS headers, the browser will not send the actual request.
  /// null = preflight echoes every Origin and the decision is made only in [PageEngine.allowOrigin] — safe
  /// only when every `cors: true` page calls `allowOrigin` itself and does not authenticate by cookie (see [Page.cors]).
  static Future<bool> Function(String origin, Uri uri)? preflightOrigin;

  /// [preflight] for an Origin let in by [preflightOrigin] (refusal = no CORS headers).
  static Future<void> preflightWithGate(HttpHeaders h, Page meta, String? origin, String? headerValues, Uri uri) =>
      _preflightWithGate(h, meta, origin, headerValues, uri);

  /// Response to the CORS preflight of a `@Page(cors: true)` route for an Origin let in by [preflightOrigin].
  static void preflight(HttpHeaders h, Page meta, String? origin, String? headerValues) =>
      _preflight(h, meta, origin, headerValues);

  /// Whether [method] passes `@Page(methods:)` (empty = any).
  static bool methodAllowed(Page meta, String method) =>
      meta.methods.isEmpty || meta.methods.contains(method.toUpperCase());

  static Map<String, String> _headerMap(HttpHeaders h) {
    final m = <String, String>{};
    h.forEach((k, v) => m[k.toLowerCase()] = v.join(', '));
    return m;
  }

  /// Error page in the panel theme. When rendering fails (e.g. a missing template),
  /// we fall back to bare HTML — the error page must not cause an error itself.
  /// HTML error page: [kind] is the text key (`not_found`, `server`, `csrf`… — [ErrorTexts]), [detail]
  /// is appended to the description (e.g. why the site is disabled). The app's `error.html` template wins over the
  /// library one (branding); the model has `t()` of [language] and the back link [Ignis.errorBackUrl].
  static Future<void> errorPage(HttpResponse res, int code, String kind,
      {String language = 'en', String detail = ''}) async {
    try {
      res.statusCode = code;
    } on StateError {
      // headers already sent — the status will not change, just close the response
      await res.close().catchError((_) {});
      return;
    }
    res.headers.contentType = ContentType.html;
    res.headers
      ..set('Cache-Control', 'no-store')
      ..set('Content-Security-Policy', csp)
      ..set('Cross-Origin-Resource-Policy', 'same-origin');
    securityHeaders(res.headers);
    final t = ErrorTexts.t(language);
    final title = t('ignis.error.$kind.title');
    var description = t('ignis.error.$kind.text');
    if (detail.isNotEmpty) description = kind == 'inactive' ? detail : '$description ($detail)';
    try {
      // icon and colour match the kind of error — a 404 is not the same as a server failure
      final (icon, color) = switch (code) {
        HttpStatus.notFound => ('fe fe-compass', 'primary'),
        HttpStatus.forbidden || HttpStatus.unauthorized => ('fe fe-lock', 'warning'),
        HttpStatus.requestEntityTooLarge => ('fe fe-upload-cloud', 'warning'),
        HttpStatus.badRequest => ('fe fe-alert-circle', 'warning'),
        _ => ('fe fe-alert-triangle', 'danger'),
      };
      res.write(Renderer.render('error.html', {
        'code': code,
        'kind': kind,
        'title': title,
        'description': description,
        'icon': icon,
        'color': color,
        'back': Ignis.errorBackUrl,
        'back_label': t('ignis.error.home'),
        'previous_label': t('ignis.error.back'),
        'brand': Ignis.brand,
        'page_title': '$code — $title',
        'language': language,
        't': t,
      }));
    } catch (e) {
      stderr.writeln('Ignis: could not render the error page: $e');
      const esc = HtmlEscape();
      res.write('<!doctype html><html lang="${esc.convert(language)}"><meta charset="utf-8"><title>$code</title>'
          '<body style="background:#1a2035;color:#dfe5f1;font:16px system-ui;padding:3rem">'
          '<h1>$code</h1><p>${esc.convert(title)}</p><p>${esc.convert(description)}</p>'
          '<a style="color:#845adf" href="${esc.convert(Ignis.errorBackUrl)}">${esc.convert(t('ignis.error.home'))}</a>');
    }
    await res.close();
  }

  /// Hydrates @Synced/@SessionSynced fields with values from Redis and returns their
  /// snapshot (to detect changes on save).
  static Future<Map<String, Object?>> _hydrateSynced(
      PageEngine page, List<SyncedMeta> fields, String? token) async {
    final snap = <String, Object?>{};
    if (fields.isEmpty) return snap;
    final cls = page.runtimeType.toString();
    for (final f in fields) {
      if (f.isSession && token == null) continue; // no session → skip session fields
      try {
        final raw = await Redis.get(f.redisKey(cls, token));
        if (raw != null) f.set(page, _parse(raw, f.type));
      } catch (e) {
        stderr.writeln('synced hydrate ${f.name}: $e'); // Redis down → default
      }
      snap[f.name] = f.get(page);
    }
    return snap;
  }

  /// Writes to Redis ONLY the synced fields this node actually changed
  /// (≠ hydrated) — so it does not clobber others' changes.
  static Future<void> _persistSynced(PageEngine page, List<SyncedMeta> fields,
      String? token, Map<String, Object?> snap) async {
    if (fields.isEmpty) return;
    final cls = page.runtimeType.toString();
    for (final f in fields) {
      if (f.isSession && token == null) continue;
      final cur = f.get(page);
      if (cur == snap[f.name]) continue; // no change
      final key = f.redisKey(cls, token);
      try {
        if (f.isSession) {
          await Redis.setEx(key, _ser(cur), Sessions.ttlSeconds); // TTL = session
        } else {
          await Redis.set(key, _ser(cur)); // global, no TTL
        }
      } catch (e) {
        stderr.writeln('synced persist ${f.name}: $e');
      }
    }
  }

  /// Deserializes a Redis value by the field type.
  static Object? _parse(String raw, Type t) {
    if (t == bool) return raw == 'true';
    if (t == int) return int.tryParse(raw) ?? 0;
    if (t == double) return double.tryParse(raw) ?? 0.0;
    return raw; // String and the rest
  }

  /// Serializes a field value to a string (Redis stores strings).
  static String _ser(Object? v) => v.toString();

  /// Writes the response from the page state: redirect > file > buffer.
  static Future<void> _flush(HttpResponse res, PageEngine page) async {
    // also for callers of handle() outside [guarded]; the page may override it below
    securityHeaders(res.headers);
    page.headers.forEach((k, v) => res.headers.set(k, v));
    htmlHeaders(res.headers, page);
    for (final c in page.cookiesOut) {
      res.headers.add(HttpHeaders.setCookieHeader, c);
    }

    // redirect takes precedence
    if (page.redirectTarget != null) {
      _redirectTo(res, page.redirectTarget!, page);
      await res.close();
      return;
    }

    // file from disk
    if (page.filePath != null) {
      final f = File(page.filePath!);
      if (!f.existsSync()) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      if (res.deadline != null) res.deadline = requestDeadline; // a file download takes longer than a form
      res.statusCode = page.status;
      res.headers.contentType =
          ContentType.parse(_mimeOf(page.filePath!));
      await res.addStream(f.openRead());
      await res.close();
      return;
    }

    // streamed response (file from storage) — no buffering in memory
    if (page.stream != null) {
      if (res.deadline != null) res.deadline = requestDeadline;
      res.statusCode = page.status;
      res.headers.contentType = ContentType.parse(page.contentType);
      await res.addStream(page.stream!);
      await res.close();
      return;
    }

    // binary response (small buffer)
    if (page.bytes != null) {
      res.statusCode = page.status;
      res.headers.contentType = ContentType.parse(page.contentType);
      res.add(page.bytes!);
      await res.close();
      return;
    }

    // API page error without its own body — the same JSON as engine errors
    if (page.meta.api && page.status >= 400 && page.outBuffer.isEmpty) {
      return apiError(res, page.status);
    }
    // HTML page error without its own body (notFound()/forbidden() in processData or insertData) —
    // error page in the page language instead of an empty response
    if (page.status >= 400 && page.outBuffer.isEmpty) {
      return errorPage(res, page.status, ErrorTexts.kindForStatus(page.status), language: page.language.isEmpty ? I18n.languages.first : page.language);
    }

    // regular response (HTML from render, or raw/JSON from the output stream)
    res.statusCode = page.status;
    res.headers.contentType = ContentType.parse(page.contentType);
    res.write(page.outBuffer.toString());
    await res.close();
  }

  /// htmx and live refresh (live.js) take only the content from the response — the panel shell
  /// (menu, topbar) is a needless render and transfer every few seconds from every open tab.
  static String layoutFor(String? Function(String) header) =>
      header('HX-Request') == 'true' || header('X-Ignis-Live') == '1' ? '_fragment.html' : '_layout.html';

  /// Dynamic response (HTML with the CSRF token, JSON with account data) — no cache, unless the page
  /// set its own Cache-Control. HTML gets the CSP in a header (also pages on their own layouts
  /// and with `write()`); the same URL gives a full page or an htmx fragment, hence Vary.
  static void htmlHeaders(HttpHeaders h, PageEngine page) => _htmlHeaders(h, page);

  /// The page's `@Action(name)` methods in order, preceded by ONE gate [PageEngine.beforeAction]
  /// (e.g. role → permission). false = the gate or the action set the response itself — no render.
  static Future<bool> runActions(PageEngine page, String name, List<Object? Function(Object)> methods) async {
    if (!await page.beforeAction(name)) {
      page.denied = true;
      return false;
    }
    for (final call in methods) {
      final r = call(page);
      if ((r is Future ? await r : r) == false) return false;
    }
    return true;
  }

  /// Sets 302 + Location. Headers and cookies are already set in _flush —
  /// repeating them here sent `Set-Cookie` twice on every sign-in.
  static void _redirectTo(HttpResponse res, String url, PageEngine page) {
    res.statusCode = HttpStatus.found; // 302
    res.headers.set(HttpHeaders.locationHeader, url);
  }

  /// Simple MIME by extension (for file()).
  static String _mimeOf(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.json')) return 'application/json';
    if (p.endsWith('.png')) return 'image/png';
    if (p.endsWith('.pdf')) return 'application/pdf';
    if (p.endsWith('.css')) return 'text/css';
    if (p.endsWith('.js')) return 'application/javascript';
    return 'application/octet-stream';
  }
}

/// State of one request shared by the [Engine.handle] steps.
class _Request {
  _Request(this.req, this.path) : res = req.response;
  final HttpRequest req;
  final HttpResponse res;
  final String path;
  PageRoute? route;
  var api = false;
  var language = '';
  late TenantContext context;
  var apiRoute = false;
  var safe = false;
  final params = <String, String>{};
  final files = <UploadedFile>[];
  final cookies = <String, String>{};
  var ip = '';
  var body = '';
  List<int> bodyBytes = const [];
  var newCsrf = false;
  var csrf = '';
  Future<void> Function()? errorEntry;

  /// share of [Engine.apiBodyBudget], held until the request is handled
  var apiBytes = 0;

  void reserve(int n) {
    if (Engine._apiBodyInFlight + n > Engine.apiBodyBudget) throw const Overloaded();
    Engine._apiBodyInFlight += n;
    apiBytes += n;
  }

  /// Error in the route's format: HTML page, or JSON for the API client.
  Future<void> error(int code, String kind, {String detail = ''}) async {
    if (!api) return Engine.errorPage(res, code, kind, language: language, detail: detail);
    await Engine.apiError(res, code);
  }
}
