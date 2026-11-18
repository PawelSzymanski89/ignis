// Lista: q/sort/kier/strona z adresu → bezpieczny SQL (biała lista sortowań) i model z linkami; makra _list.html.
import 'package:ignis/ignis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

class TestPage extends PageEngine {}

TestPage page(Map<String, String> q) => TestPage()
  ..bind(
    method: 'GET',
    meta: const Page('/app/campaigns'),
    params: {...q, 'csrf': 'tajny'},
    cookies: const {},
    context: const TenantContext(service: 0, name: 'x', domain: 'x.test', panel: false, active: true),
    query: q,
  );
const sort = {'date': 'created_at', 'name': 'lower(name)', 'wyslane': 'wyslane'};

void main() {
  final d = Listing.fromPage(page({'tenant': 'acme'}), sorting: sort, defaults: 'date', ascending: {'name'}, onPage: 10);
  check('domyślnie: data malejąco, strona 1', d.sql == ' ORDER BY created_at DESC, id DESC LIMIT 10 OFFSET 0');
  check('nieznany sort i śmieci w adresie nie trafiają do SQL',
      Listing.fromPage(page({'sort': 'x; DROP TABLE', 'page': '-3'}), sorting: sort, defaults: 'date').sql ==
          ' ORDER BY created_at DESC, id DESC LIMIT 50 OFFSET 0');
  check('ogromna strona przycięta — OFFSET nie przepełnia się na ujemny',
      Listing.fromPage(page({'page': '9223372036854775807'}), sorting: sort, defaults: 'date').offset == 999999 * 50);
  final n = Listing.fromPage(page({'tenant': 'acme', 'kanal': 'push', 'q': ' 50%_ ', 'sort': 'name', 'page': '3'}),
      sorting: sort, defaults: 'date', ascending: {'name'}, onPage: 10);
  check('nazwa bez kier → rosnąco; strona 3 → OFFSET 20', n.sql == ' ORDER BY lower(name) ASC, id ASC LIMIT 10 OFFSET 20');
  check('wzorzec ILIKE escapuje % i _', n.pattern == r'%50\%\_%');
  final m = n.model(45);
  check('liczniki: 5 stron, 21–30 z 45', m['pages'] == 5 && m['first'] == 21 && m['last'] == 30);
  check('link następnej strony zachowuje tenant, filtr, frazę i sort',
      m['next_url'] == '/app/campaigns?tenant=acme&kanal=push&q=50%25_&sort=name&dir=asc&page=4');
  final s = m['sort_links'] as Map;
  check('nagłówek aktywny odwraca kierunek, strona wraca do 1',
      s['name'] == '/app/campaigns?tenant=acme&kanal=push&q=50%25_&sort=name&dir=desc');
  check('inny nagłówek → jego domyślny kierunek', (s['date'] as String).endsWith('sort=date&dir=desc'));
  check('csrf nigdy w linkach', !'$m'.contains('tajny'));
  check('biezacy = ten sam widok (strona 3)', m['current'] == '/app/campaigns?tenant=acme&kanal=push&q=50%25_&sort=name&dir=asc&page=3');
  final fl = Listing.fromPage(page({'tenant': 'acme', 'flash': 'ok', 'flash_type': 'success', 'flash_sig': 'x'}), sorting: sort, defaults: 'date')
      .model(1);
  check('flash z poprzedniej akcji nie przechodzi do linków', !'$fl'.contains('flash'));
  check('ostatnia strona bez „następnej”', Listing.fromPage(page({'page': '5'}), sorting: sort, defaults: 'date', onPage: 10).model(45)['next_url'] == null);
  check('pusto: od 0, jedna strona', d.model(0)['first'] == 0 && d.model(0)['pages'] == 1);

  final html = Renderer.env.fromString('{% from "_list.html" import sort_th, pager, search %}'
          '{{ sort_th(l, "name", "Name") }}{{ pager(l) }}{{ search(l, "Search", placeholder="Name…") }}')
      .render(Map<String, Object?>.from(Renderer.sanitize({'l': m}) as Map));
  check('sort_th: aria-sort i link', html.contains('aria-sort="ascending"') && html.contains('sort=name&amp;dir=desc'));
  check('pager: zakres i rel=next', html.contains('21–30 of 45') && html.contains('rel="next"'));
  check('szukaj: ukryte pola bez q i strony',
      html.contains('name="kanal" value="push"') && !html.contains('name="page"') && html.contains('value="50%_"'));
  final pz = page({'tenant': 'acme', 'q': 'x', 'page': '9'});
  final lz = Listing.fromPage(pz, sorting: sort, defaults: 'date', onPage: 10);
  check('strona poza zakresem → 302 na ostatnią (25 wierszy = 3 strony), fraza zostaje',
      lz.outOfRange(25) && pz.redirectTarget == '/app/campaigns?tenant=acme&q=x&sort=date&dir=desc&page=3');
  final p0 = page({'tenant': 'acme', 'page': '2'});
  check('0 wierszy, strona=2 → strona 1 (bez parametru strona)',
      Listing.fromPage(p0, sorting: sort, defaults: 'date').outOfRange(0) && p0.redirectTarget == '/app/campaigns?tenant=acme&sort=date&dir=desc');
  final p1 = page({'tenant': 'acme', 'page': '3'});
  check('strona w zakresie → bez przekierowania', !Listing.fromPage(p1, sorting: sort, defaults: 'date', onPage: 10).outOfRange(25) && p1.redirectTarget == null);
  final fq = Listing.fromPage(page({'tenant': 'acme', 'kanal': 'push', 'status': 'szkic', 'q': '<b>'}), sorting: sort, defaults: 'date', filters: {'status'}).model(0);
  check('filtrowane + wyczyść: usuwa q i filtry, zostawia tenant i zakładkę', fq['filtered'] == true && fq['clear'] == '/app/campaigns?tenant=acme&kanal=push');
  check('bez q i filtrów → niefiltrowane', Listing.fromPage(page({'tenant': 'acme', 'kanal': 'push'}), sorting: sort, defaults: 'date', filters: {'status'}).model(0)['filtered'] == false);
  String missing(Map<String, Object?> m) => Renderer.env.fromString('{% from "_list.html" import no_results %}'
          '{{ no_results(l, for_text="Brak wyników dla", title="Nic nie pasuje", clear="Wyczyść filtry", quotes="„”") }}')
      .render(Map<String, Object?>.from(Renderer.sanitize({'l': m}) as Map));
  final bh = missing(fq);
  check('brak_wynikow: fraza escapowana w cudzysłowie + link wyczyść',
      bh.contains('Brak wyników dla „&lt;b&gt;”') && bh.contains('href="/app/campaigns?tenant=acme&amp;kanal=push">Wyczyść filtry'));
  final bs = missing(Listing.fromPage(page({'tenant': 'acme', 'status': 'szkic'}), sorting: sort, defaults: 'date', filters: {'status'}).model(0));
  check('brak_wynikow bez frazy → tytuł ogólny', bs.contains('Nic nie pasuje') && !bs.contains('Brak wyników dla'));
  check('brak_wynikow na pustej, niefiltrowanej liście → nic', missing(Listing.fromPage(page({'tenant': 'acme'}), sorting: sort, defaults: 'date').model(0)).trim().isEmpty);
  check('z_q: zakodowana fraza do linków zakładek, pusta bez szukania',
      Listing.fromPage(page({'q': 'a b&c'}), sorting: sort, defaults: 'date').model(1)['with_q'] == '&q=a+b%26c' &&
          Listing.fromPage(page({}), sorting: sort, defaults: 'date').model(1)['with_q'] == '');
  final pc = page({'tenant': 'acme', 'q': 'x', 'page': '4', 'format': 'csv'});
  final lc = Listing.fromPage(pc, sorting: sort, defaults: 'date', onPage: 10);
  check('format=csv: cały filtr bez strony (LIMIT limitCsv), bez 302 poza zakresem',
      lc.csv && lc.sql == ' ORDER BY created_at DESC, id DESC LIMIT ${Listing.limitCsv}' && !lc.outOfRange(3) && pc.redirectTarget == null);
  check('link csv: filtr + sort, bez strony', n.model(45)['csv'] == '/app/campaigns?tenant=acme&kanal=push&q=50%25_&sort=name&dir=asc&format=csv');
  check('format nie przecieka do linków widoku', !(lc.model(3)['sort_links'] as Map).values.any((v) => '$v'.contains('format')));
  check('eksport: plik CSV, bez renderu', !lc.export('kampanie', ['a', 'b'], [[1, '=x']]) && pc.responseReady &&
      pc.outBuffer.toString() == '\uFEFFa,b\r\n1,\'=x\r\n' && pc.headers['Content-Disposition']!.startsWith('attachment; filename="kampanie-'));
  final eh = Renderer.env.fromString('{% from "_list.html" import export %}{{ export(l, label="Eksport CSV") }}')
      .render(Map<String, Object?>.from(Renderer.sanitize({'l': m}) as Map));
  check('makro eksport: link download', eh.contains('download>Eksport CSV</a>') && eh.contains('format=csv'));
  check('makro eksport: pusty wynik → bez przycisku', Renderer.env.fromString('{% from "_list.html" import export %}{{ export(l) }}')
      .render(Map<String, Object?>.from(Renderer.sanitize({'l': d.model(0)}) as Map)).trim().isEmpty);
  // UX2-B-11: liczba wierszy na stronie (`na`) — tylko z listy rozmiarów, zostaje w linkach, zmiana bez strony
  final requestedSize = Listing.fromPage(page({'tenant': 'acme', 'per_page': '100', 'page': '2'}), sorting: sort, defaults: 'date');
  final nm = requestedSize.model(450);
  check('na=100: LIMIT 100 OFFSET 100, 101–200, linki stron z na', requestedSize.onPage == 100 && requestedSize.sql.contains('LIMIT 100 OFFSET 100') &&
      nm['first'] == 101 && nm['last'] == 200 && '${nm['next_url']}'.contains('per_page=100') && '${(nm['sort_links'] as Map)['name']}'.contains('per_page=100'));
  check('wybór: zaznaczony 100, ukryte bez na i strony, widoczny przy > 25 wierszach',
      (nm['sizes'] as List).where((r) => (r as Map)['selected'] == true).single['n'] == 100 &&
          !(nm['hidden_per_page'] as List).any((u) => (u as Map)['k'] == 'per_page' || u['k'] == 'page') && nm['per_page_choice'] == true &&
          Listing.fromPage(page({}), sorting: sort, defaults: 'date').model(20)['per_page_choice'] == false);
  check('na spoza listy (1000, -5, x) → domyślne 50', [for (final v in ['1000', '-5', 'x']) Listing.fromPage(page({'per_page': v}), sorting: sort, defaults: 'date').onPage]
      .every((n) => n == 50));
  final pg = Renderer.env.fromString('{% from "_list.html" import pager %}{{ pager(l, rows="Wierszy") }}')
      .render(Map<String, Object?>.from(Renderer.sanitize({'l': nm}) as Map));
  check('makro pager: select na z zaznaczonym 100 i ukrytym tenant', pg.contains('name="per_page"') && pg.contains('<option value="100" selected>') &&
      pg.contains('name="tenant" value="acme"') && pg.contains('Wierszy'));
  print('lista_test: OK');
}
