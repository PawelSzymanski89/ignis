// `x.y` on an object in a template, JIT: any public getter, read through dart:mirrors (jinja's reflection getter).
// ponytail: drop together with mirrors_scan.dart once Dart removes dart:mirrors (dart-lang/sdk#44489).
import 'package:jinja/reflection.dart' show getAttribute;

Object? readAttribute(String name, Object? object) => getAttribute(name, object);
