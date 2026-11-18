// Test tłumaczeń — wybór języka, brak klucza, t() w szablonie, ciasteczko z ?lang=. Bez bazy.
import 'dart:io';

import 'package:jinja/jinja.dart';

import '../lib/engine/annotations.dart';
import '../lib/engine/engine.dart';
import '../lib/engine/page_engine.dart';
import '../lib/engine/render.dart';
import '../lib/engine/tenant.dart';
import '../lib/engine/i18n.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

class _TestPage extends PageEngine {}

_TestPage page(Map<String, String> cookies) => _TestPage()
  ..bind(method: 'GET', meta: const Page('/x'), params: const {}, cookies: cookies,
      context: TenantContext.platformContext);

void main() {
  final catalog = Directory.systemTemp.createTempSync('i18n');
  File('${catalog.path}/en.json').writeAsStringSync('{"a.title": "Crashes", "only.en": "Only", "d.one": "{n} device", '
      '"d.other": "{n} devices"}');
  File('${catalog.path}/pl.json').writeAsStringSync('{"a.title": "Crashe", "d.one": "{n} urządzenie", "d.few": "{n} urządzenia", '
      '"d.many": "{n} urządzeń"}');
  I18n.load(catalog.path, ['en', 'pl']);

  print('wybór języka:');
  check('domyślny = pierwszy', I18n.pick() == 'en');
  check('?lang wygrywa z ciasteczkiem', I18n.pick(param: 'pl', cookieValue: 'en') == 'pl');
  check('ciasteczko wygrywa z Accept-Language',
      I18n.pick(cookieValue: 'en', acceptLanguage: 'pl-PL,pl;q=0.9') == 'en');
  check('Accept-Language z regionem', I18n.pick(acceptLanguage: 'de-DE, pl-PL;q=0.8') == 'pl');
  check('nieobsługiwany ?lang pomijany', I18n.pick(param: 'xx', cookieValue: 'pl') == 'pl');

  print('teksty:');
  check('tekst w języku', I18n.t('pl', 'a.title') == 'Crashe');
  check('brak w pl → domyślny', I18n.t('pl', 'only.en') == 'Only');
  check('brak wszędzie → klucz', I18n.t('pl', 'nie.ma') == 'nie.ma');

  print('liczebniki:');
  check('pl: 1 / 2–4 / 5 / 12 / 22 / 25 / 0', [1, 2, 4, 5, 12, 22, 25, 0].map((n) => I18n.tn('pl', 'd', n)).join('|') ==
      '1 urządzenie|2 urządzenia|4 urządzenia|5 urządzeń|12 urządzeń|22 urządzenia|25 urządzeń|0 urządzeń');
  check('en: one / other', I18n.tn('en', 'd', 1) == '1 device' && I18n.tn('en', 'd', 3) == '3 devices');
  check('format liczby', I18n.tn('pl', 'd', 1200, format: (n) => '1 200') == '1 200 urządzeń');

  print('strona i szablon:');
  final s = page(const {});
  Engine.pageLanguage(s, 'pl', const {}, 'en');
  check('page.jezyk z ?lang', s.language == 'pl');
  check('?lang zapisany w ciasteczku', s.cookiesOut.any((c) => c.startsWith('lang=pl;')));
  final html = Environment(getAttribute: Renderer.env.getAttribute)
      .fromString("{{ t('a.title') }}|{{ language }}")
      .render(Map<String, Object?>.from(Renderer.sanitize(s.model) as Map));
  check('t() w szablonie', html == 'Crashe|pl');
  final html2 = Environment(getAttribute: Renderer.env.getAttribute)
      .fromString("{{ tn('d', 3) }}|{{ tn('d', n) }}")
      .render({...Map<String, Object?>.from(Renderer.sanitize(s.model) as Map), 'n': 5});
  check('tn() w szablonie', html2 == '3 urządzenia|5 urządzeń');
  final s2 = page(const {'lang': 'pl'});
  Engine.pageLanguage(s2, 'pl', const {'lang': 'pl'}, null);
  check('to samo ciasteczko nie jest wysyłane ponownie', s2.cookiesOut.isEmpty);
  final s3 = _TestPage()
    ..bind(method: 'GET', meta: const Page('/x'), params: const {}, cookies: const {}, context: TenantContext.platformContext,
        query: const {'lang': 'en', 'next': '/app/web?tenant=a&range=7d'});
  Engine.pageLanguage(s3, 'pl', const {}, null);
  check('q_jezyka: query bez lang, zakodowane (przełącznik nie gubi dalej)',
      s3.model['q_lang'] == '&next=%2Fapp%2Fweb%3Ftenant%3Da%26range%3D7d');
  catalog.deleteSync(recursive: true);
}
