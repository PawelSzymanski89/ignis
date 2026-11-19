// Actions in the registry: @Action z klasy bazowej strony też jest akcją strony (bez bazy).
import 'package:ignis/ignis.dart';

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
  PageRegistry.build();
  final a = PageRegistry.match('/test-base-actions')!.actions;
  final page = TestPage();
  check('akcja z klasy bazowej zarejestrowana', a['wspolna']?.single(page) == true);
  check('akcja własna zarejestrowana', a['wlasna']?.single(page) == true);
  check('metoda nadpisana w podklasie — jedna pozycja (bez podwójnego wywołania), wersja podklasy',
      a['nadpisana']?.length == 1 && a['nadpisana']!.single(page) == false);
  check('nic z PageEngine', a.length == 3);
}
