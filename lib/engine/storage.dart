// ============================================================================
//  storage.dart — files in MinIO (S3) + folder structure in Postgres
// ----------------------------------------------------------------------------
//  SPLIT OF RESPONSIBILITY:
//    MinIO/S3 (private network) — bytes. One place for all nodes,
//                                  without mounting anything (nodes are unprivileged).
//    Postgres                    — folder tree and file metadata.
//
//  Object key = `t<service>/YYYY/MM/<32 hex>.<ext>`. Deliberately NOT a human-given name:
//  names repeat, change and can be hostile (`../`, control characters). Renaming
//  in the panel is an UPDATE of one field, storage stays untouched.
//
//  Configured via env (like the database — these are infrastructure credentials, not a setting
//  edited in the panel): IGNIS_S3_HOST, IGNIS_S3_PORT, IGNIS_S3_KEY, IGNIS_S3_SECRET,
//  IGNIS_S3_BUCKET. Without IGNIS_S3_HOST storage is disabled (operations throw StateError).
// ============================================================================

import 'dart:async';
import 'dart:convert' show ChunkedConversionSink;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:minio/minio.dart';
import 'package:postgres/postgres.dart' show Sql;

import 'db.dart';

class FileEntry {
  FileEntry(this.id, this.key, this.name, this.path, this.type, this.size,
      this.uploaded_by, this.uploaded_at, this.description);
  final int id;
  final String key, name, path, type, uploaded_by, uploaded_at, description;
  final int size;

  bool get isImage => type.startsWith('image/');
  String get sizeReadable => size < 1024
      ? '$size B'
      : size < 1024 * 1024
          ? '${(size / 1024).toStringAsFixed(0)} KB'
          : '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
}

class FolderEntry {
  FolderEntry(this.id, this.name, this.path, this.fileCount, this.subfolderCount);
  final int id;
  final String name, path;
  final int fileCount, subfolderCount;
  bool get isEmpty => fileCount == 0 && subfolderCount == 0;
}

class Storage {
  static Minio? _client;
  static final _rnd = Random.secure();

  static String get bucket => Platform.environment['IGNIS_S3_BUCKET'] ?? 'ignis';

  static String _required(String key) =>
      Platform.environment[key] ??
      (throw StateError('Missing $key — storage will not start with an empty key'));

  /// Without `IGNIS_S3_HOST` the system works, just without files.
  static bool get enabled => Platform.environment['IGNIS_S3_HOST'] != null;

  static Minio get client => _client ??= !enabled
      ? throw StateError('File storage disabled (no IGNIS_S3_HOST) — file operations unavailable')
      : Minio(
        endPoint: _required('IGNIS_S3_HOST'),
        port: int.parse(Platform.environment['IGNIS_S3_PORT'] ?? '9000'),
        accessKey: _required('IGNIS_S3_KEY'),
        secretKey: _required('IGNIS_S3_SECRET'),
        // HTTPS with certificate verification when IGNIS_S3_SSL=1 (traffic outside the private network; SEC-A-18)
        useSSL: Platform.environment['IGNIS_S3_SSL'] == '1',
      );

  /// Creates the bucket if it does not exist. Called once, at node startup.
  static Future<void> prepare() async {
    if (!enabled) {
      stdout.writeln('file storage disabled (no IGNIS_S3_HOST)');
      return;
    }
    if (!await client.bucketExists(bucket)) {
      await client.makeBucket(bucket);
      stdout.writeln('  + bucket $bucket');
    }
  }

  // ─────────────────────────── katalogi ───────────────────────────

  /// Normalizes a path to the `/a/b/` form — one convention across the system,
  /// so comparing and joining do not depend on how someone typed it.
  static String normalize(String s) {
    final parts = s.split('/').where((c) => c.isNotEmpty && c != '.' && c != '..');
    return parts.isEmpty ? '/' : '/${parts.join('/')}/';
  }

  /// Folder name safe for a path (no slashes or control characters).
  static String safeFolderName(String s) {
    final t = s.trim().replaceAll(RegExp(r'[^\p{L}\p{N} ._-]', unicode: true), '').trim();
    return t.length > 60 ? t.substring(0, 60) : t;
  }

  static Future<List<FolderEntry>> subfolders(String path, int service) async {
    final c = await Db.connect();
    final r = await c.execute(
      Sql.named('''SELECT f.id, f.name, f.path,
                     (SELECT count(*) FROM files p WHERE p.path = f.path AND p.service = f.service),
                     (SELECT count(*) FROM folders g WHERE g.parent = f.id)
                   FROM folders f WHERE f.service = @u
                     AND f.parent = CASE WHEN @p = '/' THEN 0
                                    ELSE (SELECT id FROM folders WHERE path = @p AND service = @u) END
                   ORDER BY f.name'''),
      parameters: {'p': normalize(path), 'u': service},
    );
    return r
        .map((x) => FolderEntry(x[0] as int, x[1] as String, x[2] as String,
            (x[3] as int?) ?? 0, (x[4] as int?) ?? 0))
        .toList();
  }

  static Future<int> createFolder(String parent, String name, String actor, int service) async {
    final clean = safeFolderName(name);
    if (clean.isEmpty) throw const StorageException('ignis.msg.storage.empty_name', 'The folder name is empty.');
    final parentPath = normalize(parent);
    final path = normalize('$parentPath$clean');

    final c = await Db.connect();
    final parentId = parentPath == '/'
        ? 0
        : ((await c.execute(Sql.named('SELECT id FROM folders WHERE path=@s AND service=@u'),
                    parameters: {'s': parentPath, 'u': service}))
                .firstOrNull?[0] as int?) ??
            0;

    final r = await c.execute(
      Sql.named('''INSERT INTO folders (name, path, parent, created_by, created_at, service)
                   VALUES (@n, @s, @r, @k, @d, @u)
                   ON CONFLICT (path, service) DO NOTHING RETURNING id'''),
      parameters: {
        'n': clean, 's': path, 'r': parentId, 'k': actor,
        'd': DateTime.now().toUtc().toIso8601String(), 'u': service,
      },
    );
    if (r.isEmpty) throw const StorageException('ignis.msg.storage.folder_exists', 'A folder with this name already exists here.');
    return r.first[0] as int;
  }

  /// Deletes a folder. Refuses when it is not empty — deleting a subtree with one
  /// click is the easiest way to lose data without a conscious decision.
  static Future<void> deleteFolder(int id, int service) async {
    final c = await Db.connect();
    final f = (await c.execute(
            Sql.named('SELECT path FROM folders WHERE id=@i AND service=@u'),
            parameters: {'i': id, 'u': service}))
        .firstOrNull;
    if (f == null) throw const StorageException('ignis.msg.storage.no_such_folder', 'No such folder.');
    final path = f[0] as String;

    final fileCount = (await c.execute(
            Sql.named('SELECT count(*) FROM files WHERE path=@s AND service=@u'),
            parameters: {'s': path, 'u': service}))
        .first[0] as int;
    final subfolderCount = (await c.execute(
            Sql.named('SELECT count(*) FROM folders WHERE parent=@i AND service=@u'), parameters: {'i': id, 'u': service}))
        .first[0] as int;
    if (fileCount > 0 || subfolderCount > 0) {
      throw StorageException('ignis.msg.storage.folder_not_empty',
          'The folder is not empty ($fileCount files, $subfolderCount subfolders).', {'files': fileCount, 'folders': subfolderCount});
    }
    await c.execute(Sql.named('DELETE FROM folders WHERE id=@i AND service=@u'), parameters: {'i': id, 'u': service});
  }

  // ─────────────────────────── files ───────────────────────────

  /// Files of a folder, newest first; [limit]/[from] — a list page.
  static Future<List<FileEntry>> files(String path, int service, {int limit = 50, int from = 0}) async {
    final r = await (await Db.connect()).execute(
      Sql.named('''SELECT id, key, name, path, type, size, uploaded_by, uploaded_at, description
                   FROM files WHERE path=@s AND service=@u ORDER BY uploaded_at DESC, id DESC
                   LIMIT @l OFFSET @o'''),
      parameters: {'s': normalize(path), 'u': service, 'l': limit, 'o': from},
    );
    return r
        .map((x) => FileEntry(x[0] as int, x[1] as String, x[2] as String, x[3] as String,
            x[4] as String, x[5] as int, x[6] as String, x[7] as String, (x[8] ?? '') as String))
        .toList();
  }

  static Future<int> fileCount(String path, int service) async => (await (await Db.connect()).execute(
          Sql.named('SELECT count(*)::int FROM files WHERE path=@s AND service=@u'),
          parameters: {'s': normalize(path), 'u': service}))
      .first[0] as int;

  static Future<FileEntry?> file(int id, int service) async {
    final r = await (await Db.connect()).execute(
      Sql.named('''SELECT id, key, name, path, type, size, uploaded_by, uploaded_at, description
                   FROM files WHERE id=@i AND service=@u'''),
      parameters: {'i': id, 'u': service},
    );
    if (r.isEmpty) return null;
    final x = r.first;
    return FileEntry(x[0] as int, x[1] as String, x[2] as String, x[3] as String,
        x[4] as String, x[5] as int, x[6] as String, x[7] as String, (x[8] ?? '') as String);
  }

  /// Uploads bytes to storage and saves the reference. Returns (id, isDuplicate).
  /// [data] in 64 KB pieces — views without copying for Uint8List; for other lists only one piece is copied at a time.
  static Stream<Uint8List> chunks(List<int> data) async* {
    const n = 64 * 1024;
    for (var i = 0; i < data.length; i += n) {
      final j = min(i + n, data.length);
      yield data is Uint8List ? Uint8List.sublistView(data, i, j) : Uint8List.fromList(data.sublist(i, j));
    }
  }

  /// sha256 in chunks without copying the whole file into an isolate. Chunks from `async*` run as microtasks, so
  /// we explicitly yield the event loop between them — 16 MB does not block other requests for ~100 ms.
  static Future<String> streamHash(Stream<List<int>> s) async {
    late Digest result;
    final input = sha256.startChunkedConversion(ChunkedConversionSink<Digest>.withCallback((d) => result = d.single));
    await for (final k in s) {
      input.add(k);
      await Future<void>.delayed(Duration.zero);
    }
    input.close();
    return result.toString();
  }

  /// Extension in the object key. Must match the serving pattern (`[a-z0-9]{1,8}`), otherwise the file
  /// takes space and always gives 404 — anything else becomes `bin`.
  static String extension(String name) {
    final e = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return RegExp(r'^[a-z0-9]{1,8}$').hasMatch(e) ? e : 'bin';
  }

  /// Advisory lock space of the space limit (first key of the pair), the second = service id.
  static const _quotaLock = 0x1915;

  static Future<(int, bool)> upload({
    required String path,
    required String name,
    required String type,
    required List<int> data,
    required String actor,
    required int service,
  }) async {
    final hash = await streamHash(chunks(data));
    final folder = normalize(path);
    final c = await Db.connect();

    // service space limit (services.limit_mb; 0 = no limit; the platform has no row)
    final limit = await c.execute(
      Sql.named('SELECT limit_mb FROM services WHERE id=@u'), parameters: {'u': service});
    final limitMb = limit.isEmpty ? 0 : (limit.first[0] as int? ?? 0);
    Future<void> checkQuota() async {
      if (limitMb <= 0) return;
      final taken = (await c.execute(
              Sql.named('SELECT coalesce(sum(size),0)::bigint FROM files WHERE service=@u'),
              parameters: {'u': service}))
          .first[0] as int;
      if (taken + data.length > limitMb * 1024 * 1024) {
        throw StorageException('ignis.msg.storage.quota', 'Out of space: the service has a $limitMb MB limit.', {'limit': limitMb});
      }
    }
    await checkQuota();

    // The same file in the same folder — we do not multiply objects in storage.
    final alreadyThere = await c.execute(
      Sql.named('SELECT id FROM files WHERE hash=@h AND path=@s AND service=@u'),
      parameters: {'h': hash, 's': folder, 'u': service},
    );
    if (alreadyThere.isNotEmpty) return (alreadyThere.first[0] as int, true);

    final ext = extension(name);
    final now = DateTime.now().toUtc(); // the year/month in the key does not depend on the node TZ; old keys stay as written
    final randomValue = List.generate(16, (_) => _rnd.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    // service prefix in the key: files of different customers do not mix in storage,
    // and the key alone shows who the object belongs to
    final key = 't$service/${now.year}/${now.month.toString().padLeft(2, '0')}/$randomValue.$ext';

    // Transfer WITHOUT a pool connection and with a deadline; the row in a short transaction right after — 16 MB to S3
    // does not hold a connection, and a failed INSERT leaves no orphan object.
    await Db.commit();
    try {
      await client.putObject(bucket, key, chunks(data), size: data.length, metadata: {'Content-Type': type})
          .timeout(transferDeadline);
    } on TimeoutException {
      await _deleteQuietly(key); // it may have arrived despite the deadline
      rethrow;
    }
    try {
      // The check above is a read before write — parallel uploads would pass it together. Again under
      // the service lock (until the end of this transaction), after the slow putObject, right before INSERT.
      if (limitMb > 0) {
        await c.execute(Sql.named('SELECT pg_advisory_xact_lock(@k::int, @u::int)'), parameters: {'k': _quotaLock, 'u': service});
        await checkQuota();
      }
      final r = await c.execute(
        Sql.named('''INSERT INTO files (key, name, path, type, size, hash, uploaded_by, uploaded_at, description, service)
                     VALUES (@k, @n, @s, @t, @r, @h, @w, @d, '', @u) RETURNING id'''),
        parameters: {
          'k': key, 'n': name, 's': folder, 't': type,
          'r': data.length, 'h': hash, 'w': actor, 'd': now.toIso8601String(),
          'u': service,
        },
      );
      await Db.commit();
      return (r.first[0] as int, false);
    } catch (_) {
      await _deleteQuietly(key);
      rethrow;
    }
  }

  /// Deadline of one transfer to storage (`IGNIS_S3_TIMEOUT_S`, 60 s by default).
  /// [Ignis.start] sets it from [Engine.parseEnvInt], so a bad value stops the node.
  static Duration transferDeadline = const Duration(seconds: 60);

  static Future<void> _deleteQuietly(String key) async {
    try {
      await client.removeObject(bucket, key).timeout(transferDeadline);
    } catch (e) {
      stderr.writeln('Ignis storage: object $key not deleted after a failed write — $e');
    }
  }

  /// Deletes the reference and the object. Order matters: storage first, then
  /// the database — the other way round would leave an object without a row, i.e. garbage nobody can find.
  /// Like [upload], the transaction so far is committed before the transfer (no pool connection held while S3
  /// answers) and the transfer has [transferDeadline].
  static Future<void> deleteFile(int id, int service) async {
    final p = await file(id, service);
    if (p == null) return;
    await Db.commit();
    // no try: an undeleted object is still public under /files/<key>, so the row stays and the error (also the
    // timeout) goes to the caller — deleting again is safe (S3 DELETE of a missing object = success)
    await client.removeObject(bucket, p.key).timeout(transferDeadline);
    await (await Db.connect()).execute(
        Sql.named('DELETE FROM files WHERE id=@i AND service=@u'),
        parameters: {'i': id, 'u': service});
  }

  static Future<void> rename(int id, String name, String description, int service) async {
    await (await Db.connect()).execute(
      Sql.named('UPDATE files SET name=@n, description=@o WHERE id=@i AND service=@u'),
      parameters: {'i': id, 'n': name.trim(), 'o': description.trim(), 'u': service},
    );
  }

  /// Moves a file to an existing folder of this service (or to `/`); any other target — [StorageException].
  static Future<void> move(int id, String target, int service) async {
    final s = normalize(target);
    final c = await Db.connect();
    if (s != '/' &&
        (await c.execute(Sql.named('SELECT 1 FROM folders WHERE path=@s AND service=@u'),
                parameters: {'s': s, 'u': service}))
            .isEmpty) {
      throw StorageException('ignis.msg.storage.no_folder', 'There is no folder $s.', {'path': s});
    }
    await c.execute(
      Sql.named('UPDATE files SET path=@s WHERE id=@i AND service=@u'),
      parameters: {'i': id, 's': s, 'u': service},
    );
  }

  /// Stream of the object content — for serving the file to a client. A key outside [service]
  /// ([allowed]) throws [StorageException].
  static Future<Stream<List<int>>> read(String key, int service) async {
    if (!allowed(key, service)) throw const StorageException('ignis.msg.storage.no_file', 'No such file.');
    return await client.getObject(bucket, key);
  }

  /// Object key of service [service]: the `t<service>/` prefix must match, otherwise customer N's file
  /// could be downloaded from any other domain (also after N is disabled — a disabled domain gets 402
  /// earlier). Keys from before multi-domain (without a prefix) belonged to the platform, so only there.
  static bool allowed(String key, int service) {
    final m = _key.firstMatch(key);
    if (m == null) return false;
    return m[1] == null ? service == 0 : int.tryParse(m[1]!) == service;
  }

  static final _key = RegExp(r'^(?:t(\d+)/)?\d{4}/\d{2}/[0-9a-f]{32}\.[A-Za-z0-9]{1,8}$');

  /// All folder paths (for the "move to" list).
  static Future<List<String>> allPaths(int service) async {
    final r = await (await Db.connect()).execute(
        Sql.named('SELECT path FROM folders WHERE service=@u ORDER BY path'),
        parameters: {'u': service});
    return ['/', ...r.map((x) => x[0] as String)];
  }

  /// Breadcrumbs for a path: [(name, path)]; [root] names `/`.
  static List<(String, String)> breadcrumbs(String path, {String root = 'Files'}) {
    final out = <(String, String)>[(root, '/')];
    var currentPage = '/';
    for (final part in normalize(path).split('/').where((c) => c.isNotEmpty)) {
      currentPage = '$currentPage$part/';
      out.add((part, currentPage));
    }
    return out;
  }

  /// Statistics for the dashboard.
  static Future<(int, int, int)> stats(int service) async {
    final c = await Db.connect();
    // ::bigint is required — sum() in Postgres returns numeric, which the driver
    // hands back as a String, not an int.
    final p = (await c.execute(
            Sql.named('SELECT count(*), coalesce(sum(size),0)::bigint FROM files WHERE service=@u'),
            parameters: {'u': service}))
        .first;
    final f = (await c.execute(Sql.named('SELECT count(*) FROM folders WHERE service=@u'),
            parameters: {'u': service}))
        .first;
    return (p[0] as int, (p[1] as int), f[0] as int);
  }
}

/// A user-facing storage refusal: [key] is the i18n key, [message] the English text, [params] fill `{name}`.
class StorageException extends FormatException {
  final String key;
  final Map<String, Object> params;
  const StorageException(this.key, super.message, [this.params = const {}]);
}
