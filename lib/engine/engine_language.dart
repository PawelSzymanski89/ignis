// ============================================================================
//  engine_language.dart — language negotiation of a request and a page
//  (part of engine.dart; the public API stays on [Engine]).
// ============================================================================

part of 'engine.dart';

String _requestLanguage(HttpRequest req) {
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

void _pageLanguage(PageEngine page, String? param, Map<String, String> cookies, String? acceptLanguage) {
  final j = I18n.pick(param: param, cookieValue: cookies[I18n.cookie], acceptLanguage: acceptLanguage);
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
