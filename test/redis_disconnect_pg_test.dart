// FIX-15: polecenie, które przekroczyło limit na starym (martwym) połączeniu, nie zamyka nowego, zdrowego.
// Pierwsze połączenie idzie do „czarnej dziury” (proxy przyjmuje i milczy), następne — do Redisa.
// Uruchomienie: tool/pg_test.sh test/redis_disconnect_pg_test.dart (potrzebny tylko Redis)
import 'dart:async';
import 'dart:io';

import 'package:ignis/engine/redis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<Object?> result(Future<Object?> f) => f.then((v) => v, onError: (Object e) => _Failing('$e'));

class _Failing {
  _Failing(this.description);
  final String description;
  @override
  String toString() => 'błąd: $description';
}

Future<void> main(List<String> a) async {
  final env = Platform.environment;
  if (env['IGNIS_REDIS_HOST'] == null) {
    print('  pominięte — brak IGNIS_REDIS_HOST (tool/pg_test.sh)');
    return;
  }
  if (a.isEmpty) {
    final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var n = 0;
    final gaps = <Socket>[];
    proxy.listen((s) async {
      if (++n == 1) {
        gaps.add(s); // przyjmuje, nie czyta, nie odpowiada, nie zamyka — jak zerwana sieć
        return;
      }
      final r = await Socket.connect(env['IGNIS_REDIS_HOST'], int.parse(env['IGNIS_REDIS_PORT'] ?? '6379'));
      s.listen(r.add, onDone: r.destroy, onError: (_) => r.destroy());
      r.listen(s.add, onDone: s.destroy, onError: (_) => s.destroy());
    });
    final p = await Process.start(Platform.resolvedExecutable, ['run', Platform.script.toFilePath(), 'dziecko'],
        environment: {'IGNIS_REDIS_PORT': '${proxy.port}'});
    p.stdout.listen(stdout.add);
    p.stderr.listen(stderr.add);
    exit(await p.exitCode);
  }

  final a1 = result(Redis.cmd(['GET', 'fix15-a'])); // połączenie A (dziura)
  await Future<void>.delayed(const Duration(milliseconds: 500));
  // też na A; 8 MB nie zmieści się w buforach, więc zamknięcie A wisi, a a2 kończy WŁASNY limit ≈2.5 s
  final a2 = result(Redis.cmd(['SET', 'fix15-b', 'x' * (8 << 20)]));
  final sw = Stopwatch()..start();
  check('polecenie na martwym połączeniu: błąd w limicie, nie po zamknięciu gniazda', await a1 is _Failing);
  // połączenie B (Redis) otwarte po porzuceniu A; BLPOP trwa, gdy a2 przekracza limit
  final b = result(Redis.cmd(['BLPOP', 'fix15-c', '1']));
  check('drugie polecenie na A też kończy się błędem', await a2 is _Failing && sw.elapsedMilliseconds < 3000);
  final rb = await b;
  check('…a spóźniony błąd z A nie zamyka nowego połączenia B (BLPOP: $rb)', rb is! _Failing);
  check('kolejne polecenia działają', await Redis.cmd(['PING']) == 'PONG');
  exit(0);
}
