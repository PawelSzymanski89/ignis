// IGNIS-052.7: the permission cache keys (perm:{login}, permgen:{login}) are built only in
// lib/engine/permissions.dart — any other place goes through Permissions.invalidate*, so a key
// rename cannot leave a stale call site (bin/purge.dart kept deleting 'perm:$l').
import 'dart:io';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  final key = RegExp(r'''['"](perm|permgen):''');
  final hits = <String>[];
  for (final dir in ['lib', 'bin']) {
    for (final f in Directory(dir).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      if (f.path.endsWith('engine/permissions.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (key.hasMatch(lines[i])) hits.add('${f.path}:${i + 1}: ${lines[i].trim()}');
      }
    }
  }
  hits.forEach(print);
  check('no perm:/permgen: key built outside permissions.dart', hits.isEmpty);
  check('purge drops the cache through Permissions.invalidateMany',
      File('bin/purge.dart').readAsStringSync().contains('Permissions.invalidateMany(logins)'));
}
