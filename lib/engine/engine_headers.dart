// ============================================================================
//  engine_headers.dart — security headers and the Content-Security-Policy
//  of node responses (part of engine.dart; the public API stays on [Engine]).
// ============================================================================

part of 'engine.dart';

/// HSTS only on request (`IGNIS_HSTS=1`): enabled behind a proxy without TLS it would lock the domain for a year.
final _hsts = Platform.environment['IGNIS_HSTS'] == '1';

void _securityHeaders(HttpHeaders h) {
  h
    ..set('X-Content-Type-Options', 'nosniff')
    ..set('Referrer-Policy', 'strict-origin-when-cross-origin')
    ..set('X-Frame-Options', 'SAMEORIGIN')
    ..set('Cross-Origin-Opener-Policy', 'same-origin')
    ..set('Permissions-Policy', 'camera=(), microphone=(), geolocation=(), payment=(), usb=()');
  if (_hsts) h.set('Strict-Transport-Security', 'max-age=31536000');
}

const _cspBase = <String, List<String>>{
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
const _cspDirectives = {
  'default-src', 'script-src', 'style-src', 'img-src', 'font-src', 'connect-src', 'object-src', 'base-uri',
  'form-action', 'frame-ancestors', 'media-src', 'frame-src', 'worker-src', 'child-src', 'manifest-src',
  'script-src-elem', 'script-src-attr', 'style-src-elem', 'style-src-attr',
};
final _cspKeyword = RegExp(r"^'(self|unsafe-inline|unsafe-eval|wasm-unsafe-eval|strict-dynamic|"
    r"unsafe-hashes|report-sample|(nonce|sha256|sha384|sha512)-[A-Za-z0-9+/_=-]+)'$");
final _cspHost = RegExp(r'^[A-Za-z0-9.*:/_%~+@\[\]-]+$');

String _buildCsp(Map<String, List<String>> extra) {
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

void _htmlHeaders(HttpHeaders h, PageEngine page) {
  if (!page.headers.containsKey('Cache-Control')) h.set('Cache-Control', 'no-store');
  if (!page.contentType.startsWith('text/html')) return;
  if (!page.headers.containsKey('Content-Security-Policy')) h.set('Content-Security-Policy', Engine.csp);
  // HTML only: /files, assets and API JSON stay loadable cross-origin
  if (!page.headers.containsKey('Cross-Origin-Resource-Policy')) h.set('Cross-Origin-Resource-Policy', 'same-origin');
  h.add('Vary', 'HX-Request, X-Ignis-Live');
}
