// Test logiki uprawnień — czysta funkcja, bez bazy i bez Redisa.
// Uruchomienie: dart test/permissions_test.dart   (asercje, zero frameworka)
import '../lib/engine/permissions.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  print('wzorce:');
  check('dokładne dopasowanie', EffectivePermissions.covers('tresc.edit', 'tresc.edit'));
  check('gwiazdka sekcji obejmuje akcję', EffectivePermissions.covers('tresc.*', 'tresc.edit'));
  check('gwiazdka globalna obejmuje wszystko', EffectivePermissions.covers('*', 'cokolwiek.tu'));
  check('gwiazdka sekcji NIE łapie innej sekcji', !EffectivePermissions.covers('tresc.*', 'media.upload'));
  check('gwiazdka sekcji NIE łapie prefiksu nazwy',
      !EffectivePermissions.covers('tresc.*', 'tresciwy.edit'));
  check('brak dopasowania', !EffectivePermissions.covers('tresc.edit', 'tresc.publish'));

  print('deny bije wszystko:');
  final u1 = EffectivePermissions(['*'], ['settings.edit']);
  check('root ma tresc.edit', u1.allows('tresc.edit'));
  check('ale NIE ma settings.edit (zakaz punktowy)', !u1.allows('settings.edit'));

  final u2 = EffectivePermissions(['tresc.*', 'media.upload'], ['tresc.publish']);
  check('pakiet daje tresc.edit', u2.allows('tresc.edit'));
  check('zakaz zabiera tresc.publish mimo wzorca tresc.*', !u2.allows('tresc.publish'));
  check('media.upload działa', u2.allows('media.upload'));

  final u3 = EffectivePermissions(['tresc.edit', 'tresc.*'], ['tresc.*']);
  check('zakaz wzorcem zabiera całą sekcję, choć nadana jawnie',
      !u3.allows('tresc.edit'));

  print('nadawanie wzorca (SEC-C-2):');
  final u5 = EffectivePermissions(['*'], ['x.y']);
  check('root z zakazem x.y NIE nada x.*', !u5.allows('x.*'));
  check('ani *', !u5.allows('*'));
  check('ale nada x.z i z.*', u5.allows('x.z') && u5.allows('z.*'));
  check('zakaz x.* blokuje nadanie x.y.*', !EffectivePermissions(['*'], ['x.*']).allows('x.y.*'));

  print('suma pakietów:');
  final u4 = EffectivePermissions(['dashboard.view', 'tresc.view', 'media.upload'], []);
  check('uprawnienie z jednego pakietu', u4.allows('dashboard.view'));
  check('uprawnienie z drugiego pakietu', u4.allows('media.upload'));
  check('czego nie ma, tego nie ma', !u4.allows('settings.edit'));

  print('przypadki brzegowe:');
  check('brak wymagania = przepuszczamy', EffectivePermissions([], []).allows(null));
  check('puste wymaganie = przepuszczamy', EffectivePermissions([], []).allows(''));
  check('konto bez niczego nie może nic', !EffectivePermissions([], []).allows('dashboard.view'));
  check('sam zakaz bez nadania też blokuje',
      !EffectivePermissions([], ['dashboard.view']).allows('dashboard.view'));

  print('SEC-C-1 — zarządzanie kontem tylko przy co najmniej tych samych uprawnieniach:');
  const catalog = ['dashboard.view', 'users.view', 'users.edit', 'permissions.edit', 'settings.edit'];
  final manager = EffectivePermissions(['dashboard.view', 'users.*'], const []);
  final root = EffectivePermissions(['*'], const []);
  check('menedżer kont NIE zarządza rootem (reset hasła, 2FA, usunięcie)', !manager.includesAll(root, catalog));
  check('root zarządza menedżerem', root.includesAll(manager, catalog));
  check('menedżer zarządza kontem z podzbiorem', manager.includesAll(EffectivePermissions(['dashboard.view'], const []), catalog));
  check('równy zarządza równym', manager.includesAll(EffectivePermissions(['users.*', 'dashboard.view'], const []), catalog));
  check('klucz spoza katalogu u celu blokuje', !manager.includesAll(EffectivePermissions(['faktury.edit'], const []), catalog));
  check('root z zakazem NIE zarządza pełnym rootem',
      !EffectivePermissions(['*'], ['settings.edit']).includesAll(root, catalog));
  check('root z zakazem zarządza kontem z tym samym zakazem',
      EffectivePermissions(['*'], ['settings.edit']).includesAll(EffectivePermissions(['users.*'], ['settings.*']), catalog));

  print('\nALL PASSED');
}
