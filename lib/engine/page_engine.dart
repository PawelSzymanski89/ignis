// ============================================================================
//  page_engine.dart — base class of every Ignis page
// ----------------------------------------------------------------------------
//  Every page class EXTENDS PageEngine and (optionally) overrides the lifecycle
//  methods. From here it has access to:
//    - get("param")           — request parameters + form fields (merged),
//    - put("name", value)     — values for the template MODEL (rendered in insertData),
//    - output stream          — raw response: write / json / file / redirect,
//                               used in gates (return false = I handled it myself).
//
//  Lifecycle (the engine calls them in this order — see engine.dart):
//    1. doBeforeProcess() : bool   — gate BEFORE authorization
//    2. isAbleToSee()      : bool   — AUTHORIZATION gate (false ⇒ redirect)
//    3. processData()      : bool   — gate AFTER authorization
//    4. insertData()       : void   — put(...) into the model; the render fires HERE
//    5. doAfterProcess()   : void   — hook AFTER render
//
//  Bool gates are two-way: true = "let it through", false = "I wrote the
//  response to the output stream myself (file/JSON/redirect), skip the render".
// ============================================================================

import 'dart:async';
import 'dart:convert';

import 'annotations.dart';
import 'audit_log.dart';
import 'i18n.dart';
import 'tenant.dart';
import 'upload.dart';
import 'orm.dart';
import 'signature.dart';

/// Base page class. The engine creates an instance per request (unnamed constructor, from the registry),
/// calls bind(), then the lifecycle methods.
abstract class PageEngine {
  // --- Input (request) -----------------------------------------------------

  /// Query parameters + form fields (POST x-www-form-urlencoded), merged.
  /// The form overrides the query on name collisions.
  final Map<String, String> _params = {};

  /// Only the parameters from the request URL (no form fields or path parameters).
  final Map<String, String> _query = {};

  /// Cookies sent by the client (e.g. the session token).
  final Map<String, String> _cookies = {};

  /// Files from a multipart form (empty for regular POSTs).
  final List<UploadedFile> _files = [];

  /// Service (tenant) resolved from the request domain — see engine/tenant.dart.
  late final TenantContext context;

  /// Address the request came from — needed wherever the trail of a decision
  /// matters (e.g. accepting a quote). Behind a trusted proxy (IGNIS_TRUSTED_PROXIES) — the first X-Forwarded-For
  /// entry from the right outside the trusted ones (`clientAddress`); without it — the socket address.
  String remoteAddress = '';

  /// Raw request body (utf8) — filled only for `@Page(api: true)`.
  String body = '';

  /// Raw body bytes for `@Page(api: true, binary: true)` (after gzip inflation); empty otherwise.
  List<int> bodyBytes = const [];

  /// Page language picked by [I18n.pick].
  String language = '';

  /// Text of [key] in the page language; `{name}` placeholders are filled from [params].
  String t(String key, [Map<String, Object> params = const {}]) {
    var text = I18n.t(language.isEmpty ? I18n.languages.first : language, key);
    params.forEach((k, v) => text = text.replaceAll('{$k}', '$v'));
    return text;
  }

  /// Request headers (lower-case names).
  final Map<String, String> _requestHeaders = {};

  /// Reads a request header. Null when missing.
  String? requestHeader(String name) => _requestHeaders[name.toLowerCase()];

  /// HTTP method of the request: GET / POST / ...
  late final String method;

  /// This page's @Page annotation (route/template/redirect...) — set by the engine.
  /// Not `final`: a front page swaps the template for a service-specific variant.
  late Page meta;

  // --- Output (response) ---------------------------------------------------

  /// Model passed to the template on render (filled by put()).
  final Map<String, Object?> _model = {};

  /// Raw response buffer (write/json/file). When non-empty and nothing is rendered,
  /// this is what gets returned.
  final StringBuffer _out = StringBuffer();

  /// Headers to add (other than cookies).
  final Map<String, String> _headers = {};

  /// Cookies to set (there may be several: session + CSRF).
  final List<String> _cookiesOut = [];

  /// Response Content-Type. HTML by default (render); json()/file() change it.
  String _contentType = 'text/html; charset=utf-8';

  /// HTTP status code of the response.
  int _status = 200;

  /// Redirect target (when set, the engine returns 302).
  String? _redirect;

  /// Response already set in insertData (e.g. [attachment] from a list CSV export) — the engine does not render the template.
  bool _ready = false;
  bool get responseReady => _ready;

  /// Path of a file to send (when set, the engine reads and sends the file).
  String? _filePath;

  /// Raw binary response (when set, it goes instead of the text buffer).
  List<int>? _bytes;

  /// Streamed response (file from storage) — the bytes do not pass through the page's memory.
  Stream<List<int>>? _stream;

  // --- Binding (called by the engine before the lifecycle) -----------------

  /// Injects request data into the page. Called by the engine before the lifecycle starts.
  void bind({
    required String method,
    required Page meta,
    required Map<String, String> params,
    required Map<String, String> cookies,
    required TenantContext context,
    List<UploadedFile> files = const [],
    String remoteAddress = '',
    Map<String, String> headerValues = const {},
    Map<String, String> query = const {},
  }) {
    _query
      ..clear()
      ..addAll(query);
    this.context = context;
    this.remoteAddress = remoteAddress;
    this.method = method;
    this.meta = meta;
    _params
      ..clear()
      ..addAll(params);
    _cookies
      ..clear()
      ..addAll(cookies);
    _files
      ..clear()
      ..addAll(files);
    _requestHeaders
      ..clear()
      ..addAll(headerValues);
  }

  // --- API for page classes ------------------------------------------------

  /// Reads a request parameter or form field. Null when missing.
  String? get(String name) => _params[name];

  /// URL (query) parameters except [skip] — for "same page, different filter" links and forms,
  /// which must keep e.g. a detail `id`. Query only: POST fields (csrf, passwords) never end up in links.
  Map<String, String> paramsWithout(Iterable<String> skip) {
    final p = skip.toSet();
    return {for (final e in _query.entries) if (!p.contains(e.key)) e.key: e.value};
  }

  /// [paramsWithout] as an encoded query suffix `&k=v…` (empty when nothing is left).
  String queryWithout(Iterable<String> skip) => [
        for (final e in paramsWithout(skip).entries)
          '&${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}'
      ].join();

  /// Puts a value into the template model. Used when rendering in insertData().
  void put(String name, Object? value) => _model[name] = value;

  /// Names of checked checkboxes sharing a prefix, without the prefix.
  /// A form with `perm_content.edit` → `paramsStartingWith('perm_')` = ['content.edit'].
  /// An unchecked checkbox is not sent in a POST — that is exactly "unchecked".
  List<String> paramsStartingWith(String prefix) => _params.keys
      .where((k) => k.startsWith(prefix))
      .map((k) => k.substring(prefix.length))
      .toList();

  /// All uploaded files.
  List<UploadedFile> get files => _files;

  /// The first file from a given form field (null when none was uploaded).
  UploadedFile? uploadedFile(String field) =>
      _files.where((p) => p.field == field).firstOrNull;

  /// How long a message lives after a redirect.
  static const flashTtl = Duration(minutes: 10);

  /// URL parameters with a signed message (`flash`, `flash_type`, `flash_sig`). The signature binds
  /// the service, this browser's CSRF token and an expiry — a signed text does not work in another
  /// service, for another person or after the deadline (SEC-A-14). `flash_sig` = `<expiry s>.<signature>`.
  String flashInUrl(String message, String type) {
    final deadline = DateTime.now().add(flashTtl).millisecondsSinceEpoch ~/ 1000;
    return 'flash=${Uri.encodeComponent(message)}&flash_type=${Uri.encodeComponent(type)}'
        '&flash_sig=$deadline.${_signFlash(deadline, type, message)}';
  }

  /// (type, message) from the URL, if the signature matches and it has not expired.
  (String, String)? flashFromUrl() {
    final f = get('flash'), type = get('flash_type') ?? 'success';
    final [deadline, signature, ...] = [...(get('flash_sig') ?? '').split('.'), '', ''];
    final t = int.tryParse(deadline);
    if (f == null || f.isEmpty || t == null || t * 1000 < DateTime.now().millisecondsSinceEpoch) return null;
    return Signing.equal(signature, _signFlash(t, type, f)) ? (type, f) : null;
  }

  String _signFlash(int deadline, String type, String message) =>
      Signing.textValue('flash', '${context.service}|${_model['csrf'] ?? ''}|$deadline|$type|$message');

  /// Reads a cookie (e.g. the session token) — useful in isAbleToSee().
  String? cookie(String name) => _cookies[name];

  /// Sets a cookie in the response (e.g. the session token after sign-in).
  void setCookie(String name, String value,
      {String path = '/', bool httpOnly = true, bool secure = true, int? maxAge}) {
    // the browser rejects __Host- without Secure or with Path≠/ — the session would silently disappear
    if (name.startsWith('__Host-') && (!secure || path != '/')) {
      throw ArgumentError('Cookie $name requires Secure and Path=/');
    }
    final b = StringBuffer('$name=$value; Path=$path; SameSite=Lax');
    if (httpOnly) b.write('; HttpOnly');
    if (secure) b.write('; Secure'); // HTTPS only (TLS at the reverse proxy)
    if (maxAge != null) b.write('; Max-Age=$maxAge');
    _cookiesOut.add(b.toString());
  }

  // --- Output stream (raw response; use + return false in a gate) ---------

  /// Appends raw text to the response buffer (no template render).
  void write(String text) => _out.write(text);

  /// Sets a JSON response (serializes the object). Content-Type = application/json.
  void json(Object? obj) {
    _contentType = 'application/json; charset=utf-8';
    _out
      ..clear()
      ..write(jsonEncode(obj));
  }

  /// JSON response with conditional GET: ETag = content digest (weak, `W/"…"`), `Cache-Control: private, max-age=[maxAge]`.
  /// When the request's `If-None-Match` contains that ETag (or `*`) → 304 without a body. The client (SDK) keeps the last
  /// response and sends its ETag, so unchanged content does not travel over the network again.
  bool conditionalJson(Object? obj, {int maxAge = 0}) {
    final content = jsonEncode(obj);
    final etag = contentEtag(content);
    header('ETag', etag);
    header('Cache-Control', 'private, max-age=$maxAge');
    if (matchesIfNoneMatch(requestHeader('if-none-match'), etag)) {
      _out.clear();
      _status = 304;
      return false;
    }
    _contentType = 'application/json; charset=utf-8';
    _out
      ..clear()
      ..write(content);
    _status = 200;
    return false;
  }

  /// CORS: the browser hands the response to a script from [origin] (route `@Page(cors: true)`). Call it only once
  /// the page has decided the origin is allowed. `Retry-After` is exposed to the script — without it a browser
  /// client will not honour the delay from 429/503 (the header is not on the "safelisted" list).
  void allowOrigin(String origin) {
    header('Access-Control-Allow-Origin', origin);
    header('Access-Control-Expose-Headers', 'Retry-After');
    // added to a Vary the page set, not over it (the HTML Vary is added at flush)
    final vary = _headers['Vary'];
    if (vary == null || vary.isEmpty) {
      header('Vary', 'Origin');
    } else if (!vary.split(',').map((v) => v.trim().toLowerCase()).contains('origin')) {
      header('Vary', '$vary, Origin');
    }
  }

  /// Sets a response header.
  void header(String name, String value) {
    if (name.toLowerCase() == 'content-type') {
      _contentType = value;
    } else {
      _headers[name] = value;
    }
  }

  /// Text to download as a file (`Content-Disposition: attachment`). The file name is
  /// trimmed to `[A-Za-z0-9._-]`, so it cannot be used to inject a header.
  /// Returns false (like the API shortcuts) — for `return attachment(...)` in a gate or action.
  bool attachment(String name, String content, {String type = 'application/octet-stream'}) {
    _ready = true;
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    header('Content-Type', type);
    header('Content-Disposition', 'attachment; filename="$safe"');
    header('Cache-Control', 'no-store');
    _out
      ..clear()
      ..write(content);
    return false;
  }

  /// Raw response bytes (image, PDF) — bypasses the text buffer.
  void saveBytes(List<int> data) => _bytes = data;

  /// Stream of response bytes — the engine copies it to the client chunk by chunk.
  void saveStream(Stream<List<int>> s) => _stream = s;

  /// Sends a file from disk (the engine reads it and sets the Content-Type by extension).
  void file(String path) => _filePath = path;

  // --- API response shortcuts (for building APIs) -------------------------
  //  All of them SET the status + (optionally) JSON and RETURN false — i.e.
  //  "stop like processData" (output stream, no render). So in a gate
  //  or an @Action you write e.g. `return notFound();` / `return ok(data);`.

  /// Sets the HTTP status of the response (e.g. status = 202).
  set httpStatus(int code) => _status = code;

  bool _api(int code, [Object? data]) {
    _status = code;
    if (data != null) json(data); // sets JSON + Content-Type
    return false; // short-circuit
  }

  bool ok([Object? data]) => _api(200, data);
  bool created([Object? data]) => _api(201, data);
  bool noContent() => _api(204);
  bool badRequest([Object? data]) => _api(400, data);
  bool unauthorized([Object? data]) => _denied(401, data);
  bool forbidden([Object? data]) => _denied(403, data);

  /// The action was denied (401/403, missing permission, closed [beforeAction]) — the result of the audit log entry.
  bool denied = false;

  bool _denied(int code, Object? data) {
    denied = true;
    return _api(code, data);
  }

  /// Gate before `@Action(name)` methods (POST only, after processData). Lets everything through by default;
  /// a page overrides it to check permissions in one place instead of in every action.
  /// false ⇒ the page set the response itself (e.g. forbidden()) and no action runs.
  Future<bool> beforeAction(String name) async => true;
  bool notFound([Object? data]) => _api(404, data);

  /// Field errors from [fieldError] (field → message key), in the order reported.
  final Map<String, String> fieldErrors = {};

  /// Form validation without PRG: the page renders again (422) with what the user typed,
  /// and the model gets `form` (action, errors, values) — the base template marks the fields and sets
  /// focus. Returns true, so an action can `return fieldError(...)` and the render goes on.
  bool fieldError(String field, String key) {
    fieldErrors.putIfAbsent(field, () => key);
    _status = 422;
    return true;
  }

  /// Fields whose values are not sent back to the browser on error (passwords, token, action button).
  static bool _withoutEcho(String field) => const {'csrf', '_csrf', 'triggerAction'}.contains(field) || AuditLog.secret(field);

  /// The `form` model for [fieldErrors] — called by the engine before render.
  void prepareFormErrors() {
    if (fieldErrors.isEmpty) return;
    put('form', {
      'action': get('triggerAction') ?? '',
      'errors': [for (final e in fieldErrors.entries) {'field': e.key, 'key': e.value}],
      'values': [
        for (final e in _params.entries)
          if (!_withoutEcho(e.key)) {'field': e.key, 'value': e.value}
      ],
    });
  }
  bool serverError([Object? data]) => _api(500, data);

  /// Any status + JSON (when the ones above are not enough).
  bool respond(int code, [Object? data]) => _api(code, data);

  /// Sets a redirect (the engine returns 302 with a Location header).
  void redirect(String url) => _redirect = url;

  // --- Lifecycle (default implementations — pages override as needed) ------

  /// 1. Before authorization. false ⇒ return the output stream, no render.
  FutureOr<bool> doBeforeProcess() => true;

  /// 2. Authorization. false ⇒ redirect to meta.redirectIfNotAbleToSee.
  FutureOr<bool> isAbleToSee() => true;

  /// 3. After authorization (user context available). false ⇒ output stream, no render.
  FutureOr<bool> processData() => true;

  /// 4. Fill the template model with put(). Running it at all = HTML render.
  FutureOr<void> insertData() {}

  /// 5. After render — logs/audit/side effects. Does not fire on a short-circuit.
  FutureOr<void> doAfterProcess() {}

  // --- Entity API (registry-driven ODM; delegates to Orm) ------------------------

  /// Saves an entity (INSERT/UPDATE) under a per-entity lock; @Cached → copy in Redis.
  Future<void> saveEntity(Object entity) => Orm.save(entity);

  /// Reads one entity of type T by id (from the cache when @Cached, otherwise from the database).
  Future<T?> readEntity<T>(Object id) => Orm.read<T>(id);

  /// Reads all entities of type T.
  Future<List<T>> readEntitys<T>() => Orm.readAll<T>();

  // --- Engine access (engine.dart) ------------------------------------------

  Map<String, Object?> get model => _model;
  StringBuffer get outBuffer => _out;
  Map<String, String> get headers => _headers;
  List<String> get cookiesOut => _cookiesOut;
  String get contentType => _contentType;
  int get status => _status;
  set status(int code) => _status = code;
  String? get redirectTarget => _redirect;
  String? get filePath => _filePath;
  List<int>? get bytes => _bytes;
  Stream<List<int>>? get stream => _stream;
}

/// Weak content ETag: `W/"<16 hex FNV-1a 64>"` — stable across processes and Dart versions (no hashCode).
String contentEtag(String content) {
  var h = 0xcbf29ce484222325;
  for (final b in utf8.encode(content)) {
    h = (h ^ b) * 0x100000001b3;
  }
  String hex(int x) => x.toRadixString(16).padLeft(8, '0');
  return 'W/"${hex((h >> 32) & 0xffffffff)}${hex(h & 0xffffffff)}"';
}

/// `If-None-Match` (a list, `*`, weak and strong comparison as in RFC 9110 §13.1.2) contains [etag].
bool matchesIfNoneMatch(String? header, String etag) {
  if (header == null || header.trim().isEmpty) return false;
  String bare(String e) => e.trim().startsWith('W/') ? e.trim().substring(2) : e.trim();
  return header.split(',').any((e) => e.trim() == '*' || bare(e) == bare(etag));
}
