// build_runner entry point (see build.yaml): one aggregating builder per package.
import 'package:build/build.dart';

import 'src/registry_builder.dart';

/// Writes `lib/ignis_registry.g.dart` — every @Entity / @Page class under `lib/`.
Builder registryBuilder(BuilderOptions options) => RegistryBuilder();
