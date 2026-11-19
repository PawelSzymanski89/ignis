// PageEngine.przedAkcja: jedna bramka przed metodami @Action — false ⇒ żadna metoda akcji nie rusza (bez bazy).
import 'package:ignis/ignis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

class TestPage extends PageEngine {
  final executed = <String>[];

  @override
  Future<bool> beforeAction(String name) async => name == 'wolno' || forbidden({'error': 'missing_permission', 'action': name});

  @Action('wolno')
  bool allowedAction() => (executed..add('wolno')).isNotEmpty;

  @Action('zakaz')
  Future<bool> forbiddenAction() async => (executed..add('zakaz')).isEmpty;
}

Future<void> main() async {
  final p1 = TestPage();
  check('bramka przepuszcza → metoda akcji wykonana, render dalej', await Engine.runActions(p1, 'wolno', [(p) => (p as TestPage).allowedAction()]) && p1.executed.join() == 'wolno');
  final p2 = TestPage();
  check('bramka odmawia → 403 z jej treścią, metoda akcji NIE wykonana',
      !await Engine.runActions(p2, 'zakaz', [(p) => (p as TestPage).forbiddenAction()]) && p2.status == 403 && p2.outBuffer.toString().contains('missing_permission') && p2.executed.isEmpty);
  final p3 = TestPage();
  check('domyślna bramka PageEngine przepuszcza', await PageEngineDefault().beforeAction('x') && await Engine.runActions(p3, 'wolno', [(p) => (p as TestPage).allowedAction()]));
}

class PageEngineDefault extends PageEngine {}
