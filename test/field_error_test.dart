// PageEngine.bladPola: 422 zamiast PRG, model `formularz` z wpisanymi wartościami (bez csrf, haseł, tokenów)
// i błędami w kolejności zgłoszenia; partial _form_errors.html escapuje to, co wpisał użytkownik.
import 'package:ignis/ignis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

class FormPage extends PageEngine {}

void main() {
  final s = FormPage()
    ..bind(
      method: 'POST',
      meta: const Page('/formularz'),
      params: {
        'csrf': 'tajny-csrf', 'triggerAction': 'save', 'name': '<b>Promo</b>', 'password': 'Sekret123!',
        'api_token': 't0k3n', 'description': 'zdanie', 'pin': '1234', 'code': '654321',
      },
      cookies: const {},
      context: const TenantContext(service: 0, name: 'x', domain: 'x.test', panel: false, active: true),
    );
  check('bladPola zwraca true (render idzie dalej)', s.fieldError('name', 'pole.nazwa') && s.fieldError('description', 'pole.opis'));
  s.fieldError('name', 'pole.drugi');
  check('status 422', s.status == 422);
  s.prepareFormErrors();
  final f = s.model['form'] as Map;
  final errors = (f['errors'] as List).cast<Map>();
  check('pierwszy błąd pola wygrywa, kolejność zachowana',
      errors.length == 2 && errors[0]['key'] == 'pole.nazwa' && errors[1]['field'] == 'description');
  final fields = {for (final w in (f['values'] as List).cast<Map>()) w['field']: w['value']};
  check('wpisane wartości wracają', fields['name'] == '<b>Promo</b>' && fields['description'] == 'zdanie');
  check('bez csrf, hasła, tokenu i triggerAction w echu',
      !fields.containsKey('pin') && !fields.containsKey('code') && !fields.containsKey('csrf') && !fields.containsKey('password') && !fields.containsKey('api_token') && !fields.containsKey('triggerAction'));
  check('akcja do wybrania formularza', f['action'] == 'save');
  final html = Renderer.render('_form_errors.html', {'form': f});
  check('partial escapuje wartość użytkownika', html.contains('&lt;b&gt;Promo&lt;/b&gt;') && !html.contains('<b>Promo'));
  check('partial bez t() pokazuje klucz', html.contains('data-field="name">pole.nazwa</p>'));
  check('bez błędów partial jest pusty', Renderer.render('_form_errors.html', const {}).trim().isEmpty);
  final clean = FormPage();
  clean.prepareFormErrors();
  check('bez bladPola nie ma modelu formularz', !clean.model.containsKey('formularz'));
}
