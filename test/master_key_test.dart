// Test Orm z kluczem głównym innym niż `id` — generowany SQL, bez bazy.
import 'package:ignis/ignis.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

@Entity('tokens', pk: 'key')
class Token {
  String key = '';
  String token = '';
}

@Entity('notatki')
class Note {
  int? id;
  String tekst = '';
}

void main() {
  EntityRegistry.build();
  final t = EntityRegistry.byType(Token);
  check('pk z adnotacji', t.pk == 'key');
  check('nonId bez kolumny pk', t.nonId.map((f) => f.name).join(',') == 'token');
  check('insert: ON CONFLICT (pk) DO NOTHING',
      Orm.insertSql(t) == 'INSERT INTO tokens (key,token) VALUES (@key,@token) ON CONFLICT (key) DO NOTHING');
  check('upsert: nadpisuje kolumny poza pk',
      Orm.upsertSql(t).endsWith('ON CONFLICT (key) DO UPDATE SET token=EXCLUDED.token'));
  check('update po pk', Orm.updateSql(t) == 'UPDATE tokens SET token=@token WHERE key=@key');
  final n = EntityRegistry.byType(Note);
  check('domyślny pk = id', n.pk == 'id');
  check('update encji z id bez zmian', Orm.updateSql(n) == 'UPDATE notatki SET tekst=@tekst WHERE id=@id');
}
