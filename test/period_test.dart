// Test Okres — preset, własny zakres, porównanie, błędy; makro _period.html.
import '../lib/engine/format.dart';
import '../lib/engine/period.dart';
import '../lib/engine/render.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  final now = DateTime.utc(2026, 11, 17, 10, 30);
  Period z(Map<String, String> p) => Period.fromParams((k) => p[k], now: now);
  final d = z({});
  check('domyślnie 7 dni: dziś + 6 pełnych (od 11.11 00:00), do teraz', d.range == '7d' && d.from == DateTime.utc(2026, 11, 11).millisecondsSinceEpoch && d.to == now.millisecondsSinceEpoch);
  check('24h od początku godziny sprzed 23 h, ziarno godzinowe', z({'range': '24h'}).from == DateTime.utc(2026, 11, 16, 11).millisecondsSinceEpoch && z({'range': '24h'}).seedValue == 'hour');
  check('90d dostępne', z({'range': '90d'}).days == 90);
  final w = z({'range': 'custom', 'from': '2026-10-01', 'to': '2026-10-31', 'compare': '1'});
  check('własny: oba dni włącznie (do = 1.11 00:00), 31 dni, dzienne', w.range == 'custom' && w.from == DateTime.utc(2026, 10, 1).millisecondsSinceEpoch &&
      w.to == DateTime.utc(2026, 11, 1).millisecondsSinceEpoch && w.days == 31 && w.seedValue == 'day');
  check('porównanie: poprzedni okres tej samej długości tuż przed', w.compare && w.previousFrom == DateTime.utc(2026, 8, 31).millisecondsSinceEpoch);
  final dz = z({'range': 'custom', 'from': '2026-11-10', 'to': '2026-11-30'});
  check('koniec w przyszłości → do teraz, zdo przycięte do dziś', dz.to == now.millisecondsSinceEpoch && dz.dateTo == '2026-11-17' && !dz.error);
  for (final (description, p) in [
    ('koniec przed początkiem', {'from': '2026-10-05', 'to': '2026-10-01'}),
    ('zła data', {'from': '2026-02-30', 'to': '2026-03-01'}),
    ('śmieci', {'from': "1' OR 1=1", 'to': '2026-03-01'}),
    ('ponad 366 dni', {'from': '2024-01-01', 'to': '2026-01-01'}),
    ('początek w przyszłości', {'from': '2026-12-01', 'to': '2026-12-02'}),
  ]) {
    final o = z({'range': 'custom', ...p});
    check('błąd ($description) → preset domyślny + blad', o.error && o.range == '7d');
  }
  check('nieznany preset → domyślny bez błędu', z({'range': '5y'}).range == '7d' && !z({'range': '5y'}).error);
  check('parametry: własny z datami i porównaniem', w.params.toString() == '{range: custom, from: 2026-10-01, to: 2026-10-31, compare: 1}');

  final m = w.model('/app/x?tenant=a&platforma=ios&');
  check('model: presety zachowują porównanie i resztę adresu', (m['presets'] as List).first['href'] == '/app/x?tenant=a&platforma=ios&range=24h&compare=1');
  check('model: przełącznik porównania wyłącza je, zostawia daty', m['toggle_compare'] == '/app/x?tenant=a&platforma=ios&range=custom&from=2026-10-01&to=2026-10-31');
  check('model: ukryte pola formularza = reszta adresu', (m['fields'] as List).map((e) => '${e['k']}=${e['v']}').join('&') == 'tenant=a&platforma=ios' && m['action'] == '/app/x');
  check('etykieta: pl krótko, en z miesiącem, rok spoza bieżącego', w.label('pl', now: now) == '01.10–31.10' &&
      w.label('en', now: now) == 'Oct 1 – Oct 31' && w.label('pl', now: DateTime.utc(2027)) == '01.10.2026–31.10.2026');
  check('model presetu: pola dat wypełnione zakresem presetu', d.model('/a?')['date_from'] == '2026-11-11' && d.model('/a?')['date_to'] == '2026-11-17');

  String html(Period o) => Renderer.env.fromString('{% from "_period.html" import period %}{{ period(o, presets={"7d": "7 dni"}, custom="Własny", error="Zły zakres") }}')
      .render(Map<String, Object?>.from(Renderer.sanitize({'o': o.model('/app/x?tenant=a&')}) as Map));
  final hw = html(w);
  check('makro: własny zakres w etykiecie, aria-current, porównanie wciśnięte',
      hw.contains('aria-current="true">Oct 1 – Oct 31 <span class="period-sign"') && hw.contains('name="compare" value="1" checked'));
  final hp = html(z({'range': '7d', 'compare': '1'}));
  check('makro: preset z porównaniem — przełącznik w panelu wyłącza je', hp.contains('role="switch" aria-checked="true">Compare to previous period: 7 dni</a>') &&
      hp.contains('href="/app/x?tenant=a&amp;range=7d"'));
  check('makro: etykieta presetu z mapy, brakująca = klucz', hw.contains('>7 dni</a>') && hw.contains('>30d</a>'));
  final hb = html(z({'range': 'custom', 'from': 'x'}));
  check('makro: błąd → panel otwarty z komunikatem', hb.contains('<details class="period-custom" open>') && hb.contains('role="alert">Zły zakres'));
  check('zmianaOkresu: wzrost pl z przecinkiem, spadek z minusem, 0 → null',
      periodChange(125, 100, 'pl')!['text'] == '+25,0\u00a0%' && periodChange(50, 100, 'en')!['direction'] == 'down' &&
          periodChange(50, 100, 'en')!['text'] == '−50.0\u00a0%' && periodChange(5, 0, 'pl') == null && periodChange(3, 3, 'pl')!['direction'] == 'flat');
  print('okres_test: OK');
}
