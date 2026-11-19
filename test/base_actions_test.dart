// PageRegistry.scanActions: @Action z klasy bazowej strony też jest akcją strony (bez bazy).
// ignore: deprecated_member_use
import 'dart:mirrors';

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

class TestPage extends SharedBase {
  @Action('wlasna')
  bool own() => true;

  @override
  @Action('nadpisana')
  bool overridden() => false;
}

void main() {
  final a = PageRegistry.scanActions(reflectClass(TestPage));
  check('akcja z klasy bazowej zarejestrowana', a['wspolna']?.single == #shared);
  check('akcja własna zarejestrowana', a['wlasna']?.single == #own);
  check('metoda nadpisana w podklasie — jedna pozycja (bez podwójnego wywołania)', a['nadpisana']?.length == 1);
  check('nic z PageEngine', a.length == 3);
}
