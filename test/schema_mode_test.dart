// IGNIS-053.8: IGNIS_SCHEMA is parsed strictly — unset/empty = update (the default), update/validate/none as given,
// anything else stops the start. Before, a typo (valdate) ran DDL like update but skipped the migrations. No database.
// Run: dart run test/schema_mode_test.dart
import 'package:ignis/engine/schema.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

bool refused(Map<String, String> env) {
  try {
    Schema.mode(env);
    return false;
  } on StateError catch (e) {
    return '$e'.contains('IGNIS_SCHEMA');
  }
}

void main() {
  check('unset → update', Schema.mode({}) == 'update');
  check('empty → update', Schema.mode({'IGNIS_SCHEMA': ''}) == 'update');
  for (final m in ['update', 'validate', 'none']) {
    check('$m → $m', Schema.mode({'IGNIS_SCHEMA': m}) == m);
  }
  for (final bad in ['valdate', 'Validate', 'UPDATE', ' validate', 'validate ', 'create', '1']) {
    check('"$bad" → StateError', refused({'IGNIS_SCHEMA': bad}));
  }
  print('\nALL PASSED');
}
