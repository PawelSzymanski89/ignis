// ============================================================================
//  registry_fingerprint.dart — is the generated registry still current?
// ----------------------------------------------------------------------------
//  The registry builder stamps lib/ignis_registry.g.dart with a [Fingerprint]: the sorted package-relative paths of
//  every lib/**.dart (except the generated file) and a sha256 over `path\n<contents>\n` of each, in that order.
//  At JIT start-up Ignis finds the package's lib/ through the package config, lists and hashes the same files,
//  and on a mismatch (a file added, removed or edited since the last build) prints ONE warning with
//  `dart run build_runner build` / `watch`, then runs on whatever the registry holds. An AOT binary has no
//  package config and no sources, so the check is skipped there.
// ============================================================================

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import 'meta.dart';
import 'registry.dart' show buildCommand, watchCommand;

/// The generated file, left out of its own fingerprint.
const generatedRegistryPath = 'lib/ignis_registry.g.dart';

/// sha256 over [sources] (package-relative paths, already sorted), each as `path\n<utf-8 contents>\n`.
/// The registry builder computes the same sum from the same files.
String fingerprintSum(List<String> sources, String Function(String path) read) {
  final bytes = <int>[];
  for (final path in sources) {
    bytes
      ..addAll(utf8.encode('$path\n'))
      ..addAll(utf8.encode(read(path)))
      ..add(0x0a);
  }
  return sha256.convert(bytes).toString();
}

/// The package root directory of [package] (the parent of its lib/), or null — AOT, or a package that is not
/// in the package config.
Directory? packageRoot(String package) {
  final Uri? lib;
  try {
    lib = Isolate.resolvePackageUriSync(Uri.parse('package:$package/'));
  } on UnsupportedError {
    return null;
  }
  if (lib == null || lib.scheme != 'file') return null;
  final dir = Directory.fromUri(lib);
  return dir.existsSync() ? dir.parent : null;
}

/// Sorted package-relative paths of lib/**.dart under [root], without the generated registry.
List<String> librarySources(Directory root) {
  final lib = Directory('${root.path}/lib');
  final prefix = root.uri.path;
  return [
    for (final f in lib.listSync(recursive: true).whereType<File>())
      if (f.path.endsWith('.dart')) f.uri.path.substring(prefix.length),
  ]
    ..remove(generatedRegistryPath)
    ..sort();
}

/// ONE warning line when the registry no longer matches the lib/ sources, or null when it matches or cannot be
/// checked (no fingerprint, or no sources on disk — AOT). [root] overrides the package-config lookup (tests).
String? staleRegistryWarning(Fingerprint? fingerprint, {Directory? root}) {
  if (fingerprint == null) return null;
  final dir = root ?? packageRoot(fingerprint.package);
  if (dir == null) return null;
  final now = librarySources(dir);
  final sum = fingerprintSum(now, (p) => File('${dir.path}/$p').readAsStringSync());
  if (sum == fingerprint.sum) return null;
  final added = now.where((p) => !fingerprint.sources.contains(p)).length;
  final removed = fingerprint.sources.where((p) => !now.contains(p)).length;
  final what = [
    if (added > 0) '$added added',
    if (removed > 0) '$removed removed',
    if (added == 0 && removed == 0) 'edited',
  ].join(', ');
  return 'Ignis WARNING: lib/ignis_registry.g.dart is out of date — files under lib/ of '
      'package:${fingerprint.package} changed since the last build ($what); the node runs on the registry as '
      'generated. Run `$buildCommand`, or keep `$watchCommand` running during development.';
}
