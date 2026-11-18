// Entry point of an Ignis node — `dart run bin/server.dart` (JIT, because of dart:mirrors).
// Page and entity barrels MUST be imported, so reflection finds the classes.
// Via package:, not '../lib/…' — otherwise the same files would come in a second time as
// file: libraries and the pages would not extend PageEngine from package:ignis.
import 'package:ignis/ignis.dart';
// ignore: unused_import
import 'package:ignis/entities.dart';
// ignore: unused_import
import 'package:ignis/pages.dart';

Future<void> main() => Ignis.start();
