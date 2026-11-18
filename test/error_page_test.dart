// Strona błędu: teksty po kluczu w języku żądania (wbudowane PL/EN, aplikacja może nadpisać), link powrotu
// z Ignis.powrotZBledu, rodzaj z kodu strony. Prawdziwy HttpServer i szablon error.html z pakietu, bez bazy.
import 'dart:io';

import '../lib/engine/engine.dart';
import '../lib/engine/ignis.dart';
import '../lib/engine/i18n.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  I18n.set({
    'pl': {'ignis.error.not_found.title': 'Tu nic nie ma'},
    'en': {},
  });
  Ignis.errorBackUrl = '/app/dashboard';
  final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  srv.listen((req) => Engine.errorPage(req.response, int.parse(req.uri.pathSegments.first),
      ErrorTexts.kindForStatus(int.parse(req.uri.pathSegments.first)), language: Engine.requestLanguage(req)));
  final k = HttpClient();
  Future<(int, String)> fetch(String p, {String? lang, String? cookie}) async {
    final r = await k.get('127.0.0.1', srv.port, p);
    if (lang != null) r.headers.set('Accept-Language', lang);
    if (cookie != null) r.headers.set('Cookie', cookie);
    final o = await r.close();
    return (o.statusCode, await o.transform(const SystemEncoding().decoder).join());
  }

  final (k1, en) = await fetch('/500', lang: 'en-GB,en;q=0.9');
  check('500 po angielsku z Accept-Language', k1 == 500 && en.contains('Something went wrong') && en.contains('</i>Back'));
  check('link powrotu do panelu aplikacji, nie /admin', en.contains('href="/app/dashboard"') && !en.contains('href="/admin"'));
  check('bez polskich resztek po angielsku', !en.contains('Wstecz') && !en.contains('Coś poszło'));
  final (_, pl) = await fetch('/500', lang: 'en', cookie: 'lang=pl');
  check('ciasteczko lang wygrywa z Accept-Language', pl.contains('Coś poszło nie tak') && pl.contains('Wstecz'));
  final (_, pl2) = await fetch('/404?lang=pl', lang: 'en');
  check('?lang wygrywa; tekst aplikacji nadpisuje wbudowany', pl2.contains('Tu nic nie ma'));
  final (k3, en3) = await fetch('/404', lang: 'en');
  check('404 po angielsku', k3 == 404 && en3.contains('Page not found'));
  final (k4, en4) = await fetch('/403', lang: 'en');
  check('403 → „Access denied”', k4 == 403 && en4.contains('Access denied'));
  check('rodzaje kodów', ErrorTexts.kindForStatus(410) == 'not_found' && ErrorTexts.kindForStatus(502) == 'server' &&
      ErrorTexts.kindForStatus(418) == 'other');
  check('język spoza listy aplikacji → wbudowany angielski', ErrorTexts.t('de')('ignis.error.not_found.title') == 'Page not found');
  k.close();
  await srv.close();
}
