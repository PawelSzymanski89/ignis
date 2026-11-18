// Test KlientPage — bez sesji klienta przekierowanie na logowanie z `dalej`, bez Redisa.
import '../lib/engine/annotations.dart';
import '../lib/engine/customer_page.dart';
import '../lib/engine/signature.dart';
import '../lib/engine/tenant.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

class _TestPage extends CustomerPage {}

Future<void> main() async {
  final s = _TestPage()
    ..bind(
        method: 'GET',
        meta: const Page('/crashe', redirectIfNotAbleToSee: '/logowanie'),
        params: const {},
        cookies: const {},
        context: TenantContext.platformContext);
  check('bez ciasteczka brama zamyka stronę', await s.doBeforeProcess() == false);
  check('przekierowanie na logowanie z dalej', s.redirectTarget == '/logowanie?next=%2Fcrashe');
  check('naLogowanie koduje trasę', CustomerPage.toLogin('/l', '/a?b=1') == '/l?next=%2Fa%3Fb%3D1');

  s.back('/kampanie?projekt=a', message: 'Wysłano', type: 'success');
  final target = Uri.parse(s.redirectTarget!);
  check('wroc: komunikat w adresie z podpisem',
      target.queryParameters['flash'] == 'Wysłano' && target.queryParameters['projekt'] == 'a');
  _TestPage page(Map<String, String> p) => _TestPage()
    ..bind(method: 'GET', meta: const Page('/x'), params: p, cookies: const {},
        context: TenantContext.platformContext);
  final ok = page(target.queryParameters)..messageFromUrl();
  check('komunikatZAdresu: podpisany trafia do szablonu', ok.model['message'] == 'Wysłano');
  final bad = page({...target.queryParameters, 'flash': 'Zaloguj się tutaj'})..messageFromUrl();
  check('komunikatZAdresu: podrobiony znika', bad.model['message'] == null);

  // SEC-A-14: podpis związany z usługą, przeglądarką (csrf) i czasem
  _TestPage zCsrf(Map<String, String> p, String csrf, [TenantContext k = TenantContext.platformContext]) => _TestPage()
    ..bind(method: 'GET', meta: const Page('/x'), params: p, cookies: const {}, context: k)
    ..put('csrf', csrf);
  final sender = zCsrf(const {}, 'csrf-ali')..back('/x', message: 'Zapisano', type: 'success');
  final q = Uri.parse(sender.redirectTarget!).queryParameters;
  check('flash_sig niesie termin', RegExp(r'^\d+\.[0-9a-f]{32}$').hasMatch(q['flash_sig']!));
  check('ta sama przeglądarka widzi komunikat', zCsrf(q, 'csrf-ali').flashFromUrl()?.$2 == 'Zapisano');
  check('link podany innej osobie (inne csrf) — znika', zCsrf(q, 'csrf-boba').flashFromUrl() == null);
  final other = TenantContext(service: 7, name: 'x', domain: 'x.pl', panel: true, active: true);
  check('w innej usłudze — znika', zCsrf(q, 'csrf-ali', other).flashFromUrl() == null);
  final [deadline, signature] = q['flash_sig']!.split('.');
  check('przesunięty termin — znika',
      zCsrf({...q, 'flash_sig': '${int.parse(deadline) + 3600}.$signature'}, 'csrf-ali').flashFromUrl() == null);
  check('zmieniony typ — znika', zCsrf({...q, 'flash_type': 'danger'}, 'csrf-ali').flashFromUrl() == null);
  final old = DateTime.now().subtract(const Duration(minutes: 1)).millisecondsSinceEpoch ~/ 1000;
  check('po terminie — znika (nawet z poprawnym podpisem)',
      zCsrf({...q, 'flash_sig': '$old.${Signing.textValue('flash', '0|csrf-ali|$old|success|Zapisano')}'}, 'csrf-ali').flashFromUrl() == null);
  check('stary format podpisu (bez terminu) — znika',
      zCsrf({...q, 'flash_sig': Signing.textValue('flash', 'success|Zapisano')}, 'csrf-ali').flashFromUrl() == null);
  check('FIX-52: podpis 128 bitów, rozdzielony celem',
      signature.length == 32 && Signing.textValue('flash', 'x') != Signing.textValue('link', 'x'));
  check('FIX-52: podpis z innym celem nie przechodzi jako flash',
      zCsrf({...q, 'flash_sig': '$deadline.${Signing.textValue('link', '0|csrf-ali|$deadline|success|Zapisano')}'}, 'csrf-ali')
              .flashFromUrl() == null);
}
