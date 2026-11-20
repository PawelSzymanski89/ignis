// ============================================================================
//  registry_builder.dart — aggregating builder: lib/**.dart → lib/ignis_registry.g.dart
// ----------------------------------------------------------------------------
//  Input is the synthetic `lib/$lib$` asset, so there is exactly ONE output per package
//  and the app needs no stub file: every library under lib/ is resolved, and every
//  public @Entity / @Page class in it lands in `ignisRegistry`. The output is a plain
//  library (not a part): it imports the scanned libraries under prefixes and builds
//  the registry from tear-offs and closures — plain code at runtime.
//
//  Annotations are matched with TypeChecker (by declaring library), never by name.
// ============================================================================

import 'dart:convert';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:crypto/crypto.dart';
import 'package:dart_style/dart_style.dart';
import 'package:glob/glob.dart';
import 'package:source_gen/source_gen.dart';

const _annotations = 'package:ignis/engine/annotations.dart';
const _entity = TypeChecker.fromUrl('$_annotations#Entity');
const _cached = TypeChecker.fromUrl('$_annotations#Cached');
const _page = TypeChecker.fromUrl('$_annotations#Page');
const _action = TypeChecker.fromUrl('$_annotations#Action');
const _synced = TypeChecker.fromUrl('$_annotations#SyncedMarker');
const _sessionSynced = TypeChecker.fromUrl('$_annotations#SessionSyncedMarker');
const _pageEngine = TypeChecker.fromUrl('package:ignis/engine/page_engine.dart#PageEngine');
const _adminPage = TypeChecker.fromUrl('package:ignis/engine/admin_page.dart#AdminPage');
const _customerPage = TypeChecker.fromUrl('package:ignis/engine/customer_page.dart#CustomerPage');

/// Name of the generated file (relative to the package root) and of its top-level variable.
const outputPath = 'lib/ignis_registry.g.dart';
const registryName = 'ignisRegistry';

class RegistryBuilder implements Builder {
  @override
  final buildExtensions = const {
    r'lib/$lib$': [outputPath],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final package = buildStep.inputId.package;
    final ids = await buildStep.findAssets(Glob('lib/**.dart')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final entities = <_Found>[];
    final pages = <_Found>[];
    // Staleness fingerprint: every lib/**.dart (except the generated file) as the start-up check re-reads them,
    // so adding, removing or editing ANY source there is noticed, not only the annotated classes.
    final sources = <String>[];
    final hash = <int>[];
    for (final id in ids) {
      if (id.path == outputPath) continue;
      sources.add(id.path);
      hash
        ..addAll(utf8.encode('${id.path}\n'))
        ..addAll(utf8.encode(await buildStep.readAsString(id)))
        ..add(0x0a);
      if (!await buildStep.resolver.isLibrary(id)) continue;
      final library = await buildStep.resolver.libraryFor(id);
      for (final cls in library.classes) {
        final isEntity = _entity.hasAnnotationOf(cls);
        final isPage = _page.hasAnnotationOf(cls);
        if (!isEntity && !isPage) continue;
        if (cls.isPrivate) {
          log.warning(
            '${_where(cls)}: private class ${cls.name} is not registered (the generated code cannot reach it)',
          );
          continue;
        }
        if (isEntity) entities.add(_Found(cls, id));
        if (isPage) pages.add(_Found(cls, id));
      }
    }
    final fingerprint = (package: package, sources: sources, sum: sha256.convert(hash).toString());

    final emitter = _Emitter(buildStep.resolver);
    final source = await emitter.emit(package, entities, pages, fingerprint);
    final formatted = DartFormatter(
      languageVersion: DartFormatter.latestLanguageVersion,
      pageWidth: 120,
    ).format(source);
    await buildStep.writeAsString(AssetId(package, outputPath), formatted);
  }
}

class _Found {
  _Found(this.cls, this.asset);
  final ClassElement cls;
  final AssetId asset;
  String get name => cls.name!;
  String get uri => cls.library.uri.toString();
}

/// `file:line` of an element — every build error and warning points at the source.
String _where(Element e) {
  final span = spanForElement(e);
  return '${span.sourceUrl}:${span.start.line + 1}';
}

Never _fail(Element e, String message) => throw InvalidGenerationSourceError('${_where(e)}: $message', element: e);

class _Emitter {
  _Emitter(this.resolver);
  final Resolver resolver;
  final _prefixes = <String, String>{};

  String _prefix(String uri) => _prefixes[uri]!;

  Future<String> emit(String package, List<_Found> entities, List<_Found> pages,
      ({String package, List<String> sources, String sum}) fingerprint) async {
    int byName(_Found a, _Found b) {
      final n = a.name.compareTo(b.name);
      return n != 0 ? n : a.uri.compareTo(b.uri);
    }

    entities.sort(byName);
    pages.sort(byName);

    // the registry is keyed by the simple class name (EntityRegistry.byType uses Type.toString())
    for (var i = 1; i < entities.length; i++) {
      if (entities[i].name == entities[i - 1].name) {
        _fail(
          entities[i].cls,
          '@Entity class ${entities[i].name} has the same name as one in ${entities[i - 1].uri} — entity names must be unique',
        );
      }
    }

    final uris = {
      for (final f in [...entities, ...pages]) f.uri,
    }.toList()..sort();
    for (var i = 0; i < uris.length; i++) {
      _prefixes[uris[i]] = 'i$i';
    }

    // Same-package libraries are imported relatively (lib/ignis_registry.g.dart sits in lib/): the program may
    // load this package by file: URIs (e.g. tests importing ../lib/…), and a package: import would then load
    // every class a second time as a different type.
    String importUri(String uri) {
      final own = 'package:$package/';
      return uri.startsWith(own) ? uri.substring(own.length) : uri;
    }

    final out = StringBuffer()
      ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND')
      ..writeln('// ignore_for_file: type=lint')
      ..writeln('//')
      ..writeln('// ignis registry builder: every @Entity / @Page class under lib/ of package:$package.')
      ..writeln('// Regenerate after changing anything under lib/: dart run build_runner build (or watch)')
      ..writeln()
      ..writeln("import '${importUri('package:ignis/engine/annotations.dart')}' as ig;")
      ..writeln("import '${importUri('package:ignis/engine/meta.dart')}' as ig;");
    for (final u in uris) {
      out.writeln("import '${importUri(u)}' as ${_prefix(u)};");
    }
    out
      ..writeln()
      ..writeln('/// Pass to `Ignis.start(registry: $registryName)` — pages and entities as plain code.')
      ..writeln('final ig.IgnisRegistry $registryName = ig.IgnisRegistry(')
      ..writeln('  entities: [');
    for (final e in entities) {
      out.writeln(await _entityMeta(e));
    }
    out.writeln('  ],\n  pages: [');
    for (final p in pages) {
      out.writeln(_pageMeta(p));
    }
    out.writeln('  ],');
    out.writeln(_attributes([...entities, ...pages]));
    out.writeln(_fingerprint(fingerprint));
    out.writeln(');');
    return out.toString();
  }

  /// `{{ obj.field }}` getters: runtime type → (public instance getter name → read closure). Covers every
  /// readable, non-static public property (fields and getters, from base classes too) of each registry class,
  /// so a template can read any of them in JIT and AOT alike.
  String _attributes(List<_Found> classes) {
    final out = StringBuffer('  attributes: {\n');
    for (final f in classes) {
      final ref = _ref(f);
      final seen = <String>{};
      final getters = <String>[];
      for (InterfaceElement? c = f.cls; c != null; c = c.supertype?.element) {
        if (c is! ClassElement) break;
        for (final g in c.getters) {
          final name = g.name;
          if (name == null || g.isStatic || g.isPrivate || name == 'hashCode' || name == 'runtimeType') continue;
          if (!seen.add(name)) continue;
          getters.add('${_str(name)}: (o) => (o as $ref).$name');
        }
      }
      out.writeln('    $ref: {${getters.join(', ')}},');
    }
    out.write('  },');
    return out.toString();
  }

  String _fingerprint(({String package, List<String> sources, String sum}) f) {
    final sources = f.sources.map(_str).join(', ');
    return '  fingerprint: const ig.Fingerprint(\n'
        '    package: ${_str(f.package)},\n'
        '    sources: [$sources],\n'
        '    sum: ${_str(f.sum)},\n'
        '  ),';
  }

  String _ref(_Found f) => '${_prefix(f.uri)}.${f.name}';

  void _checkConstructor(_Found f, String what) {
    final cls = f.cls;
    if (cls.isAbstract) _fail(cls, '$what class ${f.name} is abstract — the engine must instantiate it');
    final ctor = cls.unnamedConstructor;
    if (ctor == null) {
      _fail(
        cls,
        '$what class ${f.name} has no unnamed constructor — add `${f.name}();` (the engine calls ${f.name}.new)',
      );
    }
    if (ctor.formalParameters.any((p) => p.isRequired)) {
      _fail(
        cls,
        '$what class ${f.name}: the unnamed constructor has required parameters — the engine calls it with none',
      );
    }
  }

  Future<String> _entityMeta(_Found f) async {
    _checkConstructor(f, '@Entity');
    final cls = f.cls;
    final ref = _ref(f);
    final entity = ConstantReader(_entity.firstAnnotationOf(cls));
    final cached = _cached.firstAnnotationOf(cls);

    final fields = <String>[];
    for (final field in cls.fields) {
      if (field.isStatic || !field.isOriginDeclaration) continue;
      if (field.isPrivate) {
        log.warning('${_where(field)}: private field ${f.name}.${field.name} is not a column');
        continue;
      }
      if (field.setter == null)
        _fail(field, '@Entity field ${f.name}.${field.name} must be writable (not final/const)');
      final name = field.name!;
      fields.add(
        'ig.FieldMeta(${_str(name)}, ig.ignisFieldType(($ref o) => o.$name), '
        '(o) => (o as $ref).$name, (o, v) => (o as $ref).$name = v as dynamic, '
        'defaultValue: ${await _default(field)})',
      );
    }

    return '''
    ig.EntityMeta(
      typeName: ${_str(f.name)},
      library: ${_str(f.uri)},
      type: $ref,
      table: ${_literal(entity.read('table').objectValue)},
      pk: ${_literal(entity.read('pk').objectValue)},
      cached: ${cached != null},
      ttl: ${cached == null ? 0 : ConstantReader(cached).read('ttl').intValue},
      unique: ${_literal(entity.read('unique').objectValue)},
      ctor: $ref.new,
      fields: [${fields.join(', ')}],
    ),''';
  }

  /// The field initializer as a constant literal; a non-const initializer → null + warning.
  Future<String> _default(FieldElement field) async {
    final node = await resolver.astNodeFor(field.firstFragment, resolve: true);
    final init = node is VariableDeclaration ? node.initializer : null;
    if (init == null) return 'null';
    final value = init.computeConstantValue()?.value;
    final literal = value == null ? null : _literalOrNull(value);
    if (literal == null) {
      log.warning(
        '${_where(field)}: the initializer of ${field.enclosingElement.name}.${field.name} is not a constant '
        'String/num/bool — no column DEFAULT for it (make it a const literal)',
      );
      return 'null';
    }
    return literal;
  }

  String _pageMeta(_Found f) {
    final cls = f.cls;
    if (!_pageEngine.isSuperOf(cls)) _fail(cls, '@Page class ${f.name} must extend PageEngine');
    _checkConstructor(f, '@Page');
    final ref = _ref(f);
    final page = _page.firstAnnotationOf(cls)!;

    // @Action methods: the class first, then its bases up to PageEngine; an overridden method counts once
    final actions = <String, List<String>>{};
    final seen = <String>{};
    for (InterfaceElement? c = cls; c != null && !_pageEngine.isExactly(c); c = c.supertype?.element) {
      for (final m in c.methods) {
        if (m.isStatic || m.isOperator || !seen.add(m.name!)) continue;
        final a = _action.firstAnnotationOf(m);
        if (a == null) continue;
        if (m.isPrivate) _fail(m, '@Action method ${c.name}.${m.name} is private — the generated code cannot call it');
        if (m.formalParameters.any((p) => p.isRequired)) {
          _fail(m, '@Action method ${c.name}.${m.name} has required parameters — actions are called with none');
        }
        (actions[ConstantReader(a).read('name').stringValue] ??= []).add('(o) => (o as $ref).${m.name}()');
      }
    }

    final synced = <String>[];
    for (final field in cls.fields) {
      if (field.isStatic || !field.isOriginDeclaration) continue;
      final session = _sessionSynced.hasAnnotationOf(field);
      if (!session && !_synced.hasAnnotationOf(field)) continue;
      if (field.isPrivate) _fail(field, 'synced field ${f.name}.${field.name} is private — make it public');
      if (field.setter == null) _fail(field, 'synced field ${f.name}.${field.name} must be writable');
      final name = field.name!;
      synced.add(
        'ig.SyncedMeta(${_str(name)}, $session, ig.ignisFieldType(($ref o) => o.$name), '
        '(o) => (o as $ref).$name, (o, v) => (o as $ref).$name = v as dynamic)',
      );
    }

    final actionsSrc = [for (final e in actions.entries) '${_str(e.key)}: [${e.value.join(', ')}]'].join(', ');
    return '''
    ig.PageMeta(
      typeName: ${_str(f.name)},
      library: ${_str(f.uri)},
      page: const ${_construct('ig.Page', page)},
      ctor: $ref.new,
      cookieAuth: ${_adminPage.isSuperOf(cls) || _customerPage.isSuperOf(cls)},
      adminPage: ${_adminPage.isSuperOf(cls)},
      actions: {$actionsSrc},
      synced: [${synced.join(', ')}],
    ),''';
  }

  /// Re-creates a const annotation instance from its unnamed constructor's parameters (all `this.x`).
  String _construct(String type, DartObject value) {
    final ctor = (value.type!.element as ClassElement).unnamedConstructor!;
    final reader = ConstantReader(value);
    String arg(String name) {
      final r = reader.read(name);
      return r.isNull ? 'null' : _literal(r.objectValue);
    }

    final args = [for (final p in ctor.formalParameters) p.isNamed ? '${p.name}: ${arg(p.name!)}' : arg(p.name!)];
    return '$type(${args.join(', ')})';
  }
}

String _literal(DartObject value) =>
    _literalOrNull(value) ?? (throw UnsupportedError('ignis registry builder: unsupported constant $value'));

/// Dart source of a constant: null, String, bool, int, double or a list of those (nested).
String? _literalOrNull(DartObject value) {
  final r = ConstantReader(value);
  if (r.isNull) return 'null';
  if (r.isString) return _str(r.stringValue);
  if (r.isBool) return '${r.boolValue}';
  if (r.isInt) return '${r.intValue}';
  if (r.isDouble) {
    final d = r.doubleValue;
    return d.isFinite ? '$d' : null;
  }
  if (r.isList) {
    final items = r.listValue.map(_literalOrNull).toList();
    return items.contains(null) ? null : 'const [${items.join(', ')}]';
  }
  return null;
}

/// Single-quoted Dart string literal (escapes \, ', $ and control characters).
String _str(String s) {
  final b = StringBuffer("'");
  for (final c in s.runes) {
    switch (c) {
      case 0x5C:
        b.write(r'\\');
      case 0x27:
        b.write(r"\'");
      case 0x24:
        b.write(r'\$');
      case 0x0A:
        b.write(r'\n');
      case 0x0D:
        b.write(r'\r');
      case 0x09:
        b.write(r'\t');
      default:
        if (c < 0x20) {
          b.write('\\u{${c.toRadixString(16)}}');
        } else {
          b.writeCharCode(c);
        }
    }
  }
  b.write("'");
  return b.toString();
}
