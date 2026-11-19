// Directory of the ignis package (templates/, i18n/, web/ next to lib/).
//
// JIT: resolved from the package config. AOT (`dart compile exe`) has no package config — then
// IGNIS_PACKAGE_ROOT must point at a copy of the ignis package directory (at least templates/, i18n/, web/).
import 'dart:io';
import 'dart:isolate';

String? _root;

/// Absolute path of the ignis package root, without a trailing slash.
String ignisPackageRoot() => _root ??= _resolve();

String _resolve() {
  final env = Platform.environment['IGNIS_PACKAGE_ROOT'];
  if (env != null && env.isNotEmpty) return env.endsWith('/') ? env.substring(0, env.length - 1) : env;
  final lib = Isolate.resolvePackageUriSync(Uri.parse('package:ignis/ignis.dart'));
  if (lib == null) {
    throw StateError('Ignis: cannot find the ignis package files (templates/, i18n/, web/) — an AOT binary has no '
        'package config; set IGNIS_PACKAGE_ROOT to a copy of the ignis package directory');
  }
  return lib.resolve('..').toFilePath().replaceAll(RegExp(r'/$'), '');
}
