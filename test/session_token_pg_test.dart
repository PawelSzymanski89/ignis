// SEC-A-6: token sesji sprawdzany formatem przed Redisem; pola @SessionSynced i licznik prób 2FA
// w osobnych przestrzeniach kluczy — wartość pola nie staje się loginem sesji.
// Uruchomienie: tool/pg_test.sh test/session_token_pg_test.dart (potrzebny Redis)
import 'dart:convert';
import 'dart:io';

import 'package:ignis/engine/customer_accounts.dart';
import 'package:ignis/engine/redis.dart';
import 'package:ignis/engine/registry.dart';
import 'package:ignis/engine/session.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  if (Platform.environment['IGNIS_REDIS_HOST'] == null) {
    print('  pominięte — brak IGNIS_REDIS_HOST (tool/pg_test.sh)');
    return;
  }
  final real = await Sessions.create('ktos');
  check('prawdziwy token ma format', Sessions.validToken(real));
  check('prawdziwa sesja działa', (await Sessions.get(real))?.username == 'ktos');

  // atak: wartość pola @SessionSynced zapisana pod kluczem, który wygląda jak sesja
  final x = 'a' * 48;
  final forged = '$x:synced:Strona.pole';
  await Redis.setEx('sess:$forged', 'admin', 60);
  check('ciasteczko spoza formatu nie czyta Redisa (brak sesji admin)', await Sessions.get(forged) == null);
  check('klucz @SessionSynced nie leży pod sess:',
      !SyncedField('pole', true, String).redisKey('Strona', x).startsWith('sess:'));
  await Redis.setEx('2fa:attempt:$x', '1', 60);
  check('licznik prób nie jest czytany jako login czekający na kod', await Sessions.awaitingCode('attempt:$x') == null);
  await Redis.setEx('csess:$forged', '1|ofiara@x.pl', 60);
  check('sesja klienta też odrzuca token spoza formatu', await CustomerAccounts.session(forged, 1) == null);
  check('Sessions.zywy: zmyślony token → null', await Sessions.alive(x) == null);
  check('Sessions.zywy: żywa sesja → token', await Sessions.alive(real) == real);
  await Sessions.destroy(real);

  // SEC-A-16: wartości jako JSON — `|` w e-mailu nie przesuwa pól, stary format `a|b` nie jest czytany
  final t = 'b' * 48;
  // HARD-L.13.1: an e-mail with | is checked in customer_session_epoch_pg_test (the session reads the epoch from the database)
  await Redis.setEx('csess:${Sessions.hashToken(t)}', jsonEncode([1, 'a|x@d.pl']), 60);
  check('value without the session epoch rejected', await CustomerAccounts.session(t, 1) == null);
  await Redis.setEx('csess:${Sessions.hashToken(t)}', jsonEncode([1, 'a|x@d.pl', 0]), 60);
  check('sesja klienta w innej usłudze — brak', await CustomerAccounts.session(t, 2) == null);
  await Redis.setEx('csess:${Sessions.hashToken(t)}', '1|a', 60);
  check('stary format a|b odrzucony (bez wyjątku)', await CustomerAccounts.session(t, 1) == null);
  await Redis.del('csess:${Sessions.hashToken(t)}');
  await Redis.setEx(CustomerAccounts.resetKey(t), '1|a|x@d.pl|odcisk', 60);
  check('token resetu w starym formacie odrzucony', await CustomerAccounts.resetEmail(1, t) == null);
  await Redis.del(CustomerAccounts.resetKey(t));
  // PERF-A-3: blokady przez SCAN (cudze zostają), zbiór sesji klienta z TTL, jedno łączenie Redisa naraz
  await Redis.setEx('lock:test:moja', 'node-x', 60);
  await Redis.setEx('lock:test:cudza', 'node-y', 60);
  await Redis.releaseLocks('node-x');
  check('zwolnijBlokady: moja zdjęta, cudza zostaje',
      await Redis.get('lock:test:moja') == null && await Redis.get('lock:test:cudza') == 'node-y');
  await Redis.del('lock:test:cudza');
  await Redis.cmd(['CLIENT', 'KILL', 'TYPE', 'normal']); // zerwane połączenie (jak restart Redisa)
  try {
    await Redis.cmd(['PING']);
  } catch (_) {}
  final results = await Future.wait([for (var i = 0; i < 20; i++) Redis.cmd(['PING'])]);
  final clients = '${await Redis.cmd(['CLIENT', 'LIST'])}'.trim().split('\n').length;
  check('20 równoległych po zerwaniu → jedno połączenie', results.every((w) => w == 'PONG') && clients == 1);
  print('\nALL PASSED');
  exit(0);
}
