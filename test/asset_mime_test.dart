// Typy treści statyk /assets/ — m.in. build Flutter web (index.html, main.dart.mjs, canvaskit.wasm).
import 'package:ignis/engine/ignis.dart';

void check(String description, bool ok) {
  if (!ok) throw StateError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  check('wasm → application/wasm (CanvasKit / skwasm)', assetMime('a/canvaskit/canvaskit.wasm') == 'application/wasm');
  check('html → text/html', assetMime('inapp-preview/index.html').startsWith('text/html'));
  check('mjs i js → javascript', assetMime('x/main.dart.mjs') == 'application/javascript' && assetMime('a.JS') == 'application/javascript');
  check('dotychczasowe bez zmian (css, json, woff2), nieznane → octet-stream',
      assetMime('s.css') == 'text/css' && assetMime('m.json') == 'application/json' && assetMime('f.woff2') == 'font/woff2' &&
          assetMime('x.bin') == 'application/octet-stream');
  print('mime zasobów: wszystko ok');
}
