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
// ponytail: dart:mirrors is deprecated since Dart 3.14 (dart-lang/sdk#44489); drop this ignore when Ignis moves to explicit registration.
// ignore: deprecated_member_use
import 'dart:mirrors';
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

  static final _adminPage = reflectClass(AdminPage);

  /// Total `Content-Length` of multiparts buffered at once (`IGNIS_UPLOAD_BUDGET_MB`, 64 MB by default);
  /// above it an upload gets 503 instead of another 16 MB in RAM.
  static int multipartBudget = (int.tryParse(Platform.environment['IGNIS_UPLOAD_BUDGET_MB'] ?? '') ?? 64) * 1024 * 1024;
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
  static Duration requestDeadline = Duration(seconds: int.tryParse(Platform.environment['IGNIS_TIMEOUT_S'] ?? '') ?? 120);

  /// Limit for routes without `maxBody` (`IGNIS_SHORT_TIMEOUT_S`, 15 s by default): a plain form does not
  /// need two minutes, and a slow client should not hold the socket as long as an upload.
  static Duration shortDeadline = Duration(seconds: int.tryParse(Platform.environment['IGNIS_SHORT_TIMEOUT_S'] ?? '') ?? 15);

  static Duration routeDeadline(Page? meta) =>
      meta?.maxBody == null && shortDeadline < requestDeadline ? shortDeadline : requestDeadline;

  /// HSTS only on request (`IGNIS_HSTS=1`): enabled behind a proxy without TLS it would lock the domain for a year.
  static final _hsts = Platform.environment['IGNIS_HSTS'] == '1';

  /// Headers of every node response (pages, static files, errors) — without relying on proxy config.
  /// SAMEORIGIN, not DENY: the panel embeds its own previews in iframes.
  static void securityHeaders(HttpHeaders h) {
    h
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Referrer-Policy', 'strict-origin-when-cross-origin')
      ..set('X-Frame-Options', 'SAMEORIGIN')
      ..set('Cross-Origin-Opener-Policy', 'same-origin')
      ..set('Permissions-Policy', 'camera=(), microphone=(), geolocation=(), payment=(), usb=()');
    if (_hsts) h.set('Strict-Transport-Security', 'max-age=31536000');
  }

  /// CSP of every HTML response (pages, errors, static .html) — the `<meta>` in layouts stays as a
  /// fallback, but it does not cover `frame-ancestors` or pages on their own layouts.
  /// Set once at startup from [Ignis.start]'s `extraCsp` (see [buildCsp]).
  static String csp = buildCsp(const {});

  /// The same policy for the layouts' `<meta>` — a meta CSP ignores `frame-ancestors`.
  static String get cspMeta => csp.replaceFirst(RegExp(r"; frame-ancestors [^;]*$"), '');

  static const _cspBase = <String, List<String>>{
    'default-src': ["'self'"],
    'script-src': ["'self'"],
    'style-src': ["'self'", "'unsafe-inline'"],
    'img-src': ["'self'", 'data:'],
    'font-src': ["'self'", 'data:'],
    'connect-src': ["'self'"],
    'object-src': ["'none'"],
    'base-uri': ["'self'"],
    'form-action': ["'self'"],
  };
  static const _cspDirectives = {
    'default-src', 'script-src', 'style-src', 'img-src', 'font-src', 'connect-src', 'object-src', 'base-uri',
    'form-action', 'frame-ancestors', 'media-src', 'frame-src', 'worker-src', 'child-src', 'manifest-src',
    'script-src-elem', 'script-src-attr', 'style-src-elem', 'style-src-attr',
  };
  static final _cspKeyword = RegExp(r"^'(self|unsafe-inline|unsafe-eval|wasm-unsafe-eval|strict-dynamic|"
      r"unsafe-hashes|report-sample|(nonce|sha256|sha384|sha512)-[A-Za-z0-9+/_=-]+)'$");
  static final _cspHost = RegExp(r'^[A-Za-z0-9.*:/_%~+@\[\]-]+$');

  /// The base policy plus [extra] sources per directive (e.g. `{'img-src': ['https://cdn.example.com']}`).
  /// Throws [ArgumentError] on an unknown directive, a malformed source, `'none'`, or
  /// `'unsafe-inline'`/`'unsafe-eval'` in a `script-src*` directive (`'wasm-unsafe-eval'` is allowed).
  static String buildCsp(Map<String, List<String>> extra) {
    final policy = {for (final e in _cspBase.entries) e.key: [...e.value]};
    for (final MapEntry(key: name, value: sources) in extra.entries) {
      if (!_cspDirectives.contains(name)) throw ArgumentError.value(name, 'extraCsp', 'unknown CSP directive');
      for (final s in sources) {
        if (!_cspKeyword.hasMatch(s) && !_cspHost.hasMatch(s)) {
          throw ArgumentError.value(s, 'extraCsp[$name]', 'invalid CSP source');
        }
        if (name.startsWith('script-src') && (s == "'unsafe-inline'" || s == "'unsafe-eval'")) {
          throw ArgumentError.value(s, 'extraCsp[$name]', 'not allowed in script directives');
        }
        final list = policy[name] ??= [];
        list.remove("'none'");
        if (!list.contains(s)) list.add(s);
      }
    }
    final ancestors = ["'self'", ...?policy.remove('frame-ancestors')?.where((s) => s != "'self'")];
    return [for (final e in policy.entries) '${e.key} ${e.value.join(' ')}', 'frame-ancestors ${ancestors.join(' ')}']
        .join('; ');
  }

  /// Id of the current request (from `guarded`), or null outside a request.
  static String? get requestId => Zone.current[#ignisRequestId] as String?;

  /// Request log line: no query, body, headers or cookies.
  static String logLine(String method, String path, int code, int ms, String id) =>
      'Ignis $method $path $code ${ms}ms id=$id';

  /// Handles one HTTP request from start until the response is written.
  static Future<void> handle(HttpRequest req,
      {String? overridePath, Map<String, String>? extraParams}) async {
    final res = req.response;
    Future<void> Function()? errorEntry;
    var apiBytes = 0; // share of [apiBodyBudget], held until the request is handled
    void reserve(int n) {
      if (_apiBodyInFlight + n > apiBodyBudget) throw const Overloaded();
      _apiBodyInFlight += n;
      apiBytes += n;
    }

    try {
      final path = overridePath ?? req.uri.path;

      final route = PageRegistry.match(path);
      final api = PageRegistry.underApi(path);
      // the deadline is set by [guarded]; outside it (null) no timer that would outlive the request
      if (res.deadline != null) res.deadline = routeDeadline(route?.meta);
      // the API client is an SDK, not a browser — JSON {"error": …}, no HTML page
      final language = requestLanguage(req);
      Future<void> error(int code, String kind, {String detail = ''}) async {
        if (!api) return errorPage(res, code, kind, language: language, detail: detail);
        await apiError(res, code);
      }

      // unknown path under the API prefix — 404 without asking the database for the tenant
      if (api && route == null) return await apiError(res, HttpStatus.notFound);

      // Service from the domain. An unknown domain does NOT get a default tenant —
      // guessing here would mean showing someone another tenant's data.
      // Technical routes (health probe) are skipped: they are called by IP, without a domain.
      TenantContext context;
      if (route?.meta.technical ?? false) {
        // The probe answers only loopback and a trusted proxy (by socket address, not by Host) —
        // everyone else does not learn the state of the database, Redis or the node name.
        if (!probeAllowed(req.connectionInfo?.remoteAddress.address ?? '',
            req.headers.value('X-Forwarded-For'), trustedProxies)) {
          res.statusCode = HttpStatus.notFound;
          await res.close();
          return;
        }
        context = TenantContext.platformContext;
      } else {
        final k = await Tenants.fromHost(req.headers.host);
        if (k == null) {
          await error(HttpStatus.notFound, 'unknown_domain');
          return;
        }
        if (!k.active) {
          await error(HttpStatus.paymentRequired, 'inactive', detail: k.reason);
          return;
        }
        context = k;
      }

      // The panel lives under `admin.<domain>`, the front under the bare domain. Entering
      // /admin from the front side ended in a loop: sign-in succeeded,
      // and the first panel page sent the user back to sign-in, because the
      // "this is not the panel" barrier has no way to explain itself. We redirect to where
      // the panel actually is.
      if (!context.panel && path.startsWith('/admin')) {
        final target = 'https://admin.${context.domain}$path';
        res.statusCode = HttpStatus.movedTemporarily;
        res.headers.set(HttpHeaders.locationHeader, target);
        await res.close();
        return;
      }

      // No route → 404 in the panel theme.
      if (route == null) {
        await error(HttpStatus.notFound, 'not_found');
        return;
      }

      if (route.meta.cors && req.method == 'OPTIONS') {
        await preflightWithGate(res.headers, route.meta, req.headers.value('origin'),
            req.headers.value('access-control-request-headers'), req.uri);
        res.statusCode = HttpStatus.noContent;
        await res.close();
        return;
      }


      if (!methodAllowed(route.meta, req.method)) {
        res.headers.set(HttpHeaders.allowHeader, route.meta.methods.join(', '));
        await error(HttpStatus.methodNotAllowed, 'method', detail: req.method);
        return;
      }

      // CSRF, body and the token cookie — from THIS route's declaration. `api` (path prefix) only picks the
      // error format: a page `/admin/api/x` with `api: true` cannot lift CSRF off the whole `/admin/`.
      final apiRoute = route.meta.api;
      // methods that by definition do not change state — only they go without a CSRF token
      final safe = const {'GET', 'HEAD', 'OPTIONS'}.contains(req.method);

      // Collect the input: parameters (query+form) and cookies.
      final params = <String, String>{};
      final files = <UploadedFile>[];
      req.uri.queryParameters.forEach((k, v) => params[k] = v);
      extraParams?.forEach((k, v) => params[k] = v);
      // Client address for attempt limits — XFF only from a trusted proxy (client_ip.dart).
      final ip = clientAddress(req.connectionInfo?.remoteAddress.address ?? 'unknown',
          req.headers.value('X-Forwarded-For'), trustedProxies);

      // cookies BEFORE the body: an upload without the CSRF / session cookie is rejected without reading 16 MB (FIX-3)
      final cookies = <String, String>{};
      for (final c in req.cookies) {
        cookies[c.name] = c.value;
      }

      var body = '';
      List<int> bodyBytes = const [];
      if (apiRoute) {
        // API (SDK): raw body without form or CSRF; 2 MB on the wire (or the route's maxBody), counted incrementally
        if (const {'POST', 'PUT', 'PATCH'}.contains(req.method)) {
          final max = route.meta.maxBody;
          final limit = max ?? 2 * 1024 * 1024;
          final buffer = BytesBuilder(copy: false);
          var tooLarge = false;
          await for (final k in req) {
            if (buffer.length + k.length > limit) {
              tooLarge = true;
              break;
            }
            reserve(k.length);
            buffer.add(k);
          }
          if (tooLarge) return await apiError(res, HttpStatus.requestEntityTooLarge);
          final gzipped =
              (req.headers.value(HttpHeaders.contentEncodingHeader) ?? '').trim().toLowerCase() == 'gzip';
          try {
            final inflateLimit = max ?? 8 * 1024 * 1024;
            if (route.meta.binary) {
              bodyBytes = readBytes(buffer.takeBytes(), gzipped, limit: inflateLimit, reserve: reserve);
            } else {
              body = readBody(buffer.takeBytes(), gzipped, limit: inflateLimit, reserve: reserve);
            }
          } on UploadTooLarge {
            return await apiError(res, HttpStatus.requestEntityTooLarge);
          } on FormatException {
            return await apiError(res, HttpStatus.badRequest);
          }
        }
      } else if (req.method == 'POST' && Upload.isMultipart(req)) {
        // Upload (multipart/form-data) — dart:io does not parse it, Upload does.
        // Must run BEFORE the CSRF check, because the token arrives as a form field.
        // Only routes that declared `maxBody`: the rest (sign-in included) does not
        // accept files, and 16 MB in RAM before CSRF and auth is a free DoS (SEC-B-1).
        final max = route.meta.maxBody;
        // Without a known length (chunked) or over the limit — refused before reading; likewise without
        // the CSRF cookie (foreign form) and, on panel pages, without a live session.
        final length = req.contentLength;
        if (max == null || length < 0 || length > max) {
          await error(HttpStatus.requestEntityTooLarge, 'too_large');
          return;
        }
        if (cookies[csrfCookie] == null) {
          await error(HttpStatus.forbidden, 'csrf');
          return;
        }
        if (route.classMirror.isSubclassOf(_adminPage) && await Sessions.get(cookies[Sessions.cookieName]) == null) {
          await error(HttpStatus.forbidden, 'forbidden');
          return;
        }
        // budget of multipart bytes buffered at once on the node — parallel uploads will not eat the RAM
        if (_multipartInFlight + length > multipartBudget) {
          res.headers.set(HttpHeaders.retryAfterHeader, '5');
          await error(HttpStatus.serviceUnavailable, 'other');
          return;
        }
        _multipartInFlight += length;
        try {
          final w = await Upload.receive(req, req.headers.contentType?.parameters['boundary'], byteLimit: max);
          params.addAll(w.fields);
          files.addAll(w.files);
        } on UploadTooLarge catch (e) {
          await error(HttpStatus.requestEntityTooLarge, 'file_too_large', detail: '$e');
          return;
        } on FormatException {
          res.statusCode = HttpStatus.badRequest;
          await res.close();
          return;
        } finally {
          _multipartInFlight -= length;
        }
      } else if (!safe) {
        // body size limit (anti-DoS): 256 KB, counted INCREMENTALLY — with
        // Transfer-Encoding: chunked there is no Content-Length header (-1)
        // and an "up front" check let arbitrarily large requests through.
        const limit = 256 * 1024;
        final buffer = BytesBuilder(copy: false);
        var tooLarge = false;
        await for (final k in req) {
          if (buffer.length + k.length > limit) {
            tooLarge = true;
            break;
          }
          buffer.add(k);
        }
        if (tooLarge) {
          await error(HttpStatus.requestEntityTooLarge, 'too_large');
          return;
        }
        final body = utf8.decode(buffer.takeBytes(), allowMalformed: true);
        // x-www-form-urlencoded form → overrides the query on collision.
        // Broken encoding is a CLIENT error (400), not a server failure (500) —
        // browsers encode correctly, so it is either a bot or a hand-made request.
        try {
          if ('&'.allMatches(body).length >= maxFormFields) throw ArgumentError('too many fields');
          Uri.splitQueryString(body).forEach((k, v) => params[k] = v);
        } on ArgumentError {
          await error(HttpStatus.badRequest, 'bad_data');
          return;
        }
      }
      // AFTER parsing the body — a `__ip` form field used to override the address and reset per-IP limits.
      params['__ip'] = ip;

      // CSRF (double-submit): token in a cookie + hidden form field.
      // The `__Host-` prefix makes the browser accept this cookie only
      // without `Domain=` and only over HTTPS — so the front of a neighbouring service in the same
      // zone (a.ignis.x / b.ignis.x) cannot plant its own token via
      // `document.cookie = "...; Domain=ignis.x"`.
      final newCsrf = cookies[csrfCookie] == null;
      final csrf = cookies[csrfCookie] ?? _token();
      if (!safe && !apiRoute) {
        // POST/PUT/PATCH/DELETE must have a csrf field == the cookie (otherwise it is a foreign form).
        if (cookies[csrfCookie] == null || params['csrf'] != cookies[csrfCookie]) {
          await error(HttpStatus.forbidden, 'csrf');
          return;
        }
      }

      // SERVICE CONTEXT FOR RLS: from here on the rest of the request runs on ONE
      // connection with `ignis.service` set. Postgres policies
      // read that value, so a forgotten `WHERE service` in code stops
      // showing other tenants' data — this is the last line of defence, not a substitute for the filter.
      // The connection and transaction start on the FIRST query (a page without queries takes nothing),
      // and are returned BEFORE the response is sent: a slow client (upload, file download) does not hold the pool
      // (PERF-A-1). `noDb` pages have no context at all.
      final process = route.meta.noDb
          ? (Future<PageEngine> Function() f) => f()
          : (Future<PageEngine> Function() f) => Db.inContext(context.service, f);
      final ready = await process(() async {
        // Build a fresh page instance and inject the request.
        final page = route.newInstance();
        page.bind(
          method: req.method,
          meta: route.meta,
          // {name} path segments override query/form parameters of the same name
          params: {...params, ...?PageRegistry.pathParams(route.meta.route, path)},
          cookies: cookies,
          context: context,
          files: files,
          remoteAddress: ip,
          headerValues: _headerMap(req.headers),
          query: req.uri.queryParameters,
        );
        page.body = body;
        page.bodyBytes = bodyBytes;

        if (!apiRoute) {
          page.put('csrf', csrf); // available in templates as {{csrf}}
          if (newCsrf) page.setCookie(csrfCookie, csrf, httpOnly: true);
          pageLanguage(page, params['lang'], cookies, req.headers.value('accept-language'));
        }

        // Hydrate @Synced/@SessionSynced fields from Redis — visible for the whole lifecycle.
        // Session fields only for a live session: a made-up cookie neither creates nor reads keys.
        final token = route.syncedFields.any((f) => f.isSession)
            ? await Sessions.alive(cookies[Sessions.cookieName])
            : null;
        final snap = await _hydrateSynced(page, route.syncedFields, token);

        // ---- LIFECYCLE (one exit at the end) ---------------------------

        if (!await page.doBeforeProcess()) {
          // 1) gate before auth — false ⇒ the page handled the response itself (output stream)
        } else if (!await page.isAbleToSee()) {
          // 2) authorization — false ⇒ redirect to meta.redirectIfNotAbleToSee.
          // a password set by someone else: we lead to the password change, not
          // to sign-in — sending to sign-in would look like a broken session
          if (page is AdminPage && page.mustChangePassword && page.session != null) {
            page.redirect('/admin/account');
            return page;
          }
          page.redirect(page.meta.redirectIfNotAbleToSee);
        } else if (!await page.processData()) {
          // 3) gate after auth — false ⇒ the page handled the response itself
        } else {
          // 3.5) ACTIONS — triggerAction=<name> runs @Action(name) methods BEFORE
          // insertData. An action returns bool: false ⇒ it handled the response itself
          // (e.g. redirect/JSON in the output stream) → render skipped, as with the other gates.
          // POST ONLY: the CSRF token is checked only for POST, so an action
          // triggered from the query string (GET) would bypass it with a plain link.
          var proceed = true;
          final same = params['triggerAction'];
          if (req.method == 'POST' && same != null && route.actions.containsKey(same)) {
            // TRAIL: every panel action reaches the audit log from here, not separately
            // in each page — otherwise the first new page would drop out of the audit
            // and nobody would notice until someone asks "who changed this".
            // An exception after the action rolls back the request transaction (often already aborted) with the entry — the
            // `error` entry then goes in a separate transaction after ROLLBACK (catch below), otherwise no trace would remain.
            if (page is AdminPage && page.login.isNotEmpty) {
              Future<void> entry(String result) => AuditLog.save(
                    service: context.service,
                    actor: page.login,
                    location: route.meta.route,
                    action: same,
                    detail: AuditLog.describe(params),
                    ip: ip,
                    result: result,
                  );
              final service = context.service;
              errorEntry = () => Db.inContext(service, () => entry('error'));
              proceed = await runActions(page, same, route.actions[same]!);
              await entry(page.denied ? 'denied' : 'ok');
            } else {
              proceed = await runActions(page, same, route.actions[same]!);
            }
          }
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
            page.put('layout', layoutFor(req.headers.value));
            page.write(Renderer.render(page.meta.template, page.model));
            await page.doAfterProcess();
          }
        }

        // Persist changed synced fields (after all processing, before the response).
        await _persistSynced(page, route.syncedFields, token, snap);
        return page;
      });
      // transaction committed and connection back in the pool — only now we write to the client
      await _flush(res, ready);
    } on Overloaded {
      // full bcrypt queue — the client should retry in a moment, this is not a failure
      try {
        res.headers.set(HttpHeaders.retryAfterHeader, '5');
      } catch (_) {}
      if (PageRegistry.underApi(overridePath ?? req.uri.path)) {
        return apiError(res, HttpStatus.serviceUnavailable);
      }
      await errorPage(res, HttpStatus.serviceUnavailable, 'other', language: requestLanguage(req));
    } catch (e, st) {
      // Stack ONLY to the server log; the client gets a generic error (no leak).
      // Details ONLY to the server log — the client must not see the stack trace.
      stderr.writeln('Ignis 500 id=$requestId: $e\n$st');
      try {
        await errorEntry?.call();
      } catch (e) {
        stderr.writeln('Ignis audit log: error entry not saved: $e');
      }
      if (PageRegistry.underApi(overridePath ?? req.uri.path)) {
        return apiError(res, HttpStatus.internalServerError);
      }
      await errorPage(res, HttpStatus.internalServerError, 'server', language: requestLanguage(req));
    } finally {
      _apiBodyInFlight -= apiBytes;
    }
  }

  /// Page language for a request without a page (engine error) — the same rules as [pageLanguage].
  static String requestLanguage(HttpRequest req) {
    String? cookie;
    try {
      cookie = req.cookies.where((c) => c.name == I18n.cookie).firstOrNull?.value;
    } catch (_) {
      // a broken Cookie header must not block the error page
    }
    String? param;
    try {
      param = req.uri.queryParameters['lang'];
    } catch (_) {
      // broken %-encoding — the error page must go out anyway
    }
    return I18n.pick(param: param, cookieValue: cookie, acceptLanguage: req.headers.value('accept-language'));
  }

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
      String? acceptLanguage) {
    final j = I18n.pick(
        param: param, cookieValue: cookies[I18n.cookie], acceptLanguage: acceptLanguage);
    if (param == j && cookies[I18n.cookie] != j) {
      page.setCookie(I18n.cookie, j, maxAge: 365 * 24 * 3600);
    }
    page.language = j;
    page.put('language', j);
    page.put('languages', I18n.languages);
    page.put('q_lang', page.queryWithout(const ['lang']));
    page.put('t', (String key) => I18n.t(j, key));
    page.put('tn', (String key, Object? n) => I18n.tn(j, key, n is num ? n.toInt() : int.tryParse('$n') ?? 0));
  }

  /// Preflight gate: the app says whether [origin] may call its API at all (e.g. it is on the site list
  /// of some project). Refusal = 204 without CORS headers, the browser will not send the actual request.
  /// null = preflight reflects every Origin and the decision is made only in [PageEngine.allowOrigin] — safe
  /// only when every `cors: true` page calls `allowOrigin` itself and does not authenticate by cookie (see [Page.cors]).
  static Future<bool> Function(String origin, Uri uri)? preflightOrigin;

  /// [preflight] for an Origin let in by [preflightOrigin] (refusal = no CORS headers).
  static Future<void> preflightWithGate(HttpHeaders h, Page meta, String? origin, String? headerValues, Uri uri) async {
    if (origin == null || origin.isEmpty) return;
    final gate = preflightOrigin;
    if (gate != null && !await gate(origin, uri)) return;
    preflight(h, meta, origin, headerValues);
  }

  /// Response to the CORS preflight of a `@Page(cors: true)` route for an Origin let in by [preflightOrigin].
  static void preflight(HttpHeaders h, Page meta, String? origin, String? headerValues) {
    if (origin == null || origin.isEmpty) return;
    h.set('Access-Control-Allow-Origin', origin);
    h.set('Access-Control-Allow-Methods', [...(meta.methods.isEmpty ? const ['GET', 'POST'] : meta.methods), 'OPTIONS'].join(', '));
    if (headerValues != null && headerValues.isNotEmpty) h.set('Access-Control-Allow-Headers', headerValues);
    h.set('Access-Control-Max-Age', '86400');
    h.set('Vary', 'Origin');
  }

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
      ..set('Content-Security-Policy', csp);
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
      PageEngine page, List<SyncedField> fields, String? token) async {
    final snap = <String, Object?>{};
    if (fields.isEmpty) return snap;
    final im = reflect(page);
    final cls = page.runtimeType.toString();
    for (final f in fields) {
      if (f.isSession && token == null) continue; // no session → skip session fields
      try {
        final raw = await Redis.get(f.redisKey(cls, token));
        if (raw != null) im.setField(Symbol(f.name), _parse(raw, f.type));
      } catch (e) {
        stderr.writeln('synced hydrate ${f.name}: $e'); // Redis down → default
      }
      snap[f.name] = im.getField(Symbol(f.name)).reflectee;
    }
    return snap;
  }

  /// Writes to Redis ONLY the synced fields this node actually changed
  /// (≠ hydrated) — so it does not clobber others' changes.
  static Future<void> _persistSynced(PageEngine page, List<SyncedField> fields,
      String? token, Map<String, Object?> snap) async {
    if (fields.isEmpty) return;
    final im = reflect(page);
    final cls = page.runtimeType.toString();
    for (final f in fields) {
      if (f.isSession && token == null) continue;
      final cur = im.getField(Symbol(f.name)).reflectee;
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
  static void htmlHeaders(HttpHeaders h, PageEngine page) {
    if (!page.headers.containsKey('Cache-Control')) h.set('Cache-Control', 'no-store');
    if (!page.contentType.startsWith('text/html')) return;
    if (!page.headers.containsKey('Content-Security-Policy')) h.set('Content-Security-Policy', csp);
    h.add('Vary', 'HX-Request, X-Ignis-Live');
  }

  /// The page's `@Action(name)` methods in order, preceded by ONE gate [PageEngine.beforeAction]
  /// (e.g. role → permission). false = the gate or the action set the response itself — no render.
  static Future<bool> runActions(PageEngine page, String name, List<Symbol> methods) async {
    if (!await page.beforeAction(name)) {
      page.denied = true;
      return false;
    }
    final im = reflect(page);
    for (final sym in methods) {
      final r = im.invoke(sym, const []).reflectee;
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
