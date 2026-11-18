// Magazyn.kawalki / skrotStrumienia — ten sam sha256 co jednorazowy, kawałki składają się w całość; bez MinIO.
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ignis/engine/storage.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  // FIX-34: rozszerzenie w kluczu zawsze pasuje do wzorca serwowania
  for (final (n, e) in [('a.PDF', 'pdf'), ('a.tar.gz', 'gz'), ('bez', 'bin'), ('a.tar-gz', 'bin'),
      ('a.my_ext', 'bin'), ('a.dziewiecio', 'bin'), ('a.', 'bin'), ('a.żółw', 'bin'), ('a.12345678', '12345678')]) {
    check('rozszerzenie $n → $e', Storage.extension(n) == e);
  }
  for (final n in [0, 1, 65536, 65537, 3 * 65536 + 17]) {
    final b = Uint8List.fromList(List.generate(n, (i) => i * 31 % 251));
    final k = await Storage.chunks(b).toList();
    check('$n B: kawałki ≤64 KB składają się w całość',
        k.every((x) => x.length <= 65536) && k.expand((x) => x).length == n && k.expand((x) => x).toList().toString() == b.toList().toString());
    check('$n B: skrót strumieniowy == jednorazowy', await Storage.streamHash(Storage.chunks(b)) == sha256.convert(b).toString());
    check('$n B: List<int> (nie Uint8List) — ten sam skrót', await Storage.streamHash(Storage.chunks(b.toList())) == sha256.convert(b).toString());
  }
}
