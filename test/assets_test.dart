// Test plikZasobu — statyki aplikacji przed katalogiem biblioteki, bez serwera.
import 'dart:io';

import '../lib/engine/ignis.dart';
import '../lib/engine/render.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  final t = Directory.systemTemp.createTempSync('zasoby');
  try {
    final app = Directory('${t.path}/app')..createSync();
    final lib = Directory('${t.path}/lib')..createSync();
    File('${app.path}/a.css').writeAsStringSync('aplikacja');
    File('${lib.path}/a.css').writeAsStringSync('biblioteka');
    File('${lib.path}/b.css').writeAsStringSync('tylko biblioteka');
    final k = [app.path, lib.path];
    check('aplikacja wygrywa', assetFile(k, 'a.css')!.readAsStringSync() == 'aplikacja');
    check('brak w aplikacji → biblioteka', assetFile(k, 'b.css')!.readAsStringSync() == 'tylko biblioteka');
    check('brak nigdzie → null', assetFile(k, 'c.css') == null);
    check('.. odrzucone', assetFile(k, '../lib/a.css') == null);

    String v(String html) => RegExp(r'\?v=([0-9a-f]{10})"').firstMatch(html)![1]!;
    final html = versionAssets(
        '<link href="/assets/a.css"><script src="/assets/b.css"></script><img src="/assets/c.css">', k);
    final va = v(html.split('<script')[0]), vb = v(html.split('<script')[1]);
    check('dwa różne pliki → różne v', va != vb);
    check('brak pliku → adres bez zmian', html.contains('src="/assets/c.css">'));
    File('${app.path}/d.css').writeAsStringSync('raz');
    final d1 = v(versionAssets('<link href="/assets/d.css">', k));
    File('${app.path}/d.css').writeAsStringSync('dwa');
    assetVersions.clear(); // restart procesu
    final d2 = v(versionAssets('<link href="/assets/d.css">', k));
    check('zmiana treści → zmiana v', d1 != d2);
  } finally {
    t.deleteSync(recursive: true);
  }
  final w = assetFile(['/nie-ma', Renderer.packageAssets], 'ignis/picker.js');
  check('statyki pakietu (web/ obok lib/) — /assets/ignis/picker.js i .css', w != null && assetFile([Renderer.packageAssets], 'ignis/picker.css') != null);
  check('wybierak: combobox + listbox, Escape, change na selekcie', ["'combobox'", 'listbox', "'Escape'", "new Event('change'"].every(w!.readAsStringSync().contains));
}
