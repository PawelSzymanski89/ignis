// SEC-A-13: ciasteczka sesji z prefiksem __Host- (Secure, Path=/, bez Domain); w Redisie tylko skrót tokenu.
// Uruchomienie: tool/pg_test.sh test/session_cookies_pg_test.dart (potrzebny Redis)
import 'dart:io';

import 'package:ignis/engine/customer_accounts.dart';
import 'package:ignis/engine/orm.dart';
import 'package:ignis/engine/page_engine.dart';
import 'package:ignis/engine/redis.dart';
import 'package:ignis/engine/schema.dart';
import 'package:ignis/engine/session.dart';
// ignore: unused_import
import 'package:ignis/entities.dart';
import 'package:ignis/ignis_registry.g.dart';
import 'pg_guard.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

class _TestPage extends PageEngine {}

Future<void> main() async {
  check('ciasteczko panelu z __Host-', Sessions.cookieName.startsWith('__Host-'));
  check('ciasteczko klienta z __Host-', CustomerAccounts.cookie.startsWith('__Host-'));
  final s = _TestPage()..setCookie(Sessions.cookieName, 'x', maxAge: 10);
  final header = s.cookiesOut.single;
  check('Set-Cookie: Secure, Path=/, bez Domain',
      header.contains('; Secure') && header.contains('Path=/;') && !header.contains('Domain'));
  Object? error;
  try {
    _TestPage().setCookie(Sessions.cookieName, 'x', secure: false);
  } on ArgumentError catch (e) {
    error = e;
  }
  check('__Host- bez Secure → błąd zamiast cicho odrzuconego ciasteczka', error != null);

  if (Platform.environment['IGNIS_REDIS_HOST'] == null) {
    print('  pominięte (Redis) — brak IGNIS_REDIS_HOST');
    return;
  }
  if (skipDestructive()) return;
  // sesja czyta epokę konta z bazy (FIX-30) — tabela users musi istnieć
  EntityRegistry.build(ignisRegistry);
  await Schema.sync();
  final token = await Sessions.create('zrzut');
  check('surowy token nie jest kluczem Redisa', await Redis.get('sess:$token') == null);
  check('klucz to skrót tokenu', (await Redis.get('sess:${Sessions.hashToken(token)}'))!.contains('"zrzut"'));
  check('sesja po tokenie z ciasteczka działa', (await Sessions.get(token))?.username == 'zrzut');
  check('zbiór sesji konta bez surowego tokenu', !(await Redis.smembers('sessuser:zrzut')).contains(token));
  await Sessions.destroyAll('zrzut');
  check('destroyAll działa na skrótach', await Sessions.get(token) == null);
  print('\nALL PASSED');
  exit(0);
}
