// Actions in the registry: @Action z klasy bazowej strony też jest akcją strony (bez bazy).
import 'package:ignis/ignis.dart';

import 'registry_helper.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

abstract class SharedBase extends PageEngine {
  @Action('wspolna')
  bool shared() => true;

  @Action('nadpisana')
  bool overridden() => true;
}

@Page('/test-base-actions')
class TestPage extends SharedBase {
  @Action('wlasna')
  bool own() => true;

  @override
  @Action('nadpisana')
  bool overridden() => false;
}

void main() {
  // The generated registry collects @Action from base classes (an override counts once, the subclass version);
  // here we register the same shape the builder would and check PageRegistry exposes and invokes it.
  PageRegistry.build(testRegistry(pages: [
    testPage(const Page('/test-base-actions'), TestPage.new, actions: {
      'wspolna': [(o) => (o as TestPage).shared()],
      'nadpisana': [(o) => (o as TestPage).overridden()],
      'wlasna': [(o) => (o as TestPage).own()],
    })
  ]));
  final a = PageRegistry.match('/test-base-actions')!.actions;
  final page = TestPage();
  check('akcja z klasy bazowej zarejestrowana', a['wspolna']?.single(page) == true);
  check('akcja własna zarejestrowana', a['wlasna']?.single(page) == true);
  check('metoda nadpisana w podklasie — jedna pozycja (bez podwójnego wywołania), wersja podklasy',
      a['nadpisana']?.length == 1 && a['nadpisana']!.single(page) == false);
  check('nic z PageEngine', a.length == 3);
}
