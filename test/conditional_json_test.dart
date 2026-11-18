// Warunkowy GET (ETag / If-None-Match → 304) w PageEngine.jsonWarunkowy — bez bazy i sieci.
import '../lib/engine/annotations.dart';
import '../lib/engine/page_engine.dart';
import '../lib/engine/tenant.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

class _TestPage extends PageEngine {}

_TestPage page([Map<String, String> headerValues = const {}]) => _TestPage()
  ..bind(method: 'GET', meta: const Page('/x', api: true), params: const {}, cookies: const {},
      context: TenantContext.platformContext, headerValues: headerValues);

void main() {
  final a = page()..conditionalJson({'flags': {'a': true}}, maxAge: 60);
  final etag = a.headers['ETag']!;
  check('200 z treścią, ETag słaby, Cache-Control', a.status == 200 && a.outBuffer.toString() == '{"flags":{"a":true}}' &&
      RegExp(r'^W/"[0-9a-f]{16}"$').hasMatch(etag) && a.headers['Cache-Control'] == 'private, max-age=60');
  check('ETag stabilny dla tej samej treści', contentEtag('{"x":1}') == contentEtag('{"x":1}') && contentEtag('{"x":1}') != contentEtag('{"x":2}'));
  final b = page({'if-none-match': etag})..conditionalJson({'flags': {'a': true}});
  check('ten sam ETag → 304 bez treści, ETag nadal w odpowiedzi', b.status == 304 && b.outBuffer.isEmpty && b.headers['ETag'] == etag);
  final c = page({'if-none-match': etag})..conditionalJson({'flags': {'a': false}});
  check('zmiana treści → 200', c.status == 200 && c.outBuffer.isNotEmpty);
  check('lista, mocny vs słaby, *', matchesIfNoneMatch('"zz", ${etag.substring(2)}', etag) && matchesIfNoneMatch('*', etag) &&
      !matchesIfNoneMatch('"zz"', etag) && !matchesIfNoneMatch('', etag) && !matchesIfNoneMatch(null, etag));
}
