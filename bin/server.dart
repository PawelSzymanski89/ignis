// Entry point of an Ignis node — `dart run bin/server.dart`, or AOT: `dart compile exe bin/server.dart`.
// Pages and entities come from the generated registry (lib/ignis_registry.g.dart, `dart run build_runner build`).
// Via package:, not '../lib/…' — otherwise the same files would come in a second time as
// file: libraries and the pages would not extend PageEngine from package:ignis.
import 'package:ignis/ignis.dart';
import 'package:ignis/ignis_registry.g.dart';

Future<void> main() => Ignis.start(registry: ignisRegistry);
