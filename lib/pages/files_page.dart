// ============================================================================
//  files_page.dart — "/admin/files": the CMS file manager
// ----------------------------------------------------------------------------
//  Folder tree and metadata in Postgres, bytes in MinIO (see engine/storage.dart).
//  Folder navigation goes through the `?f=/path/` parameter, so every view can be
//  linked and refreshed — no browser-side state.
// ============================================================================

import 'dart:io';

import '../engine/admin_page.dart';
import '../engine/annotations.dart';
import '../engine/list.dart';
import '../engine/storage.dart';
import '../engine/page_engine.dart';

@Page('/admin/files',
    template: 'files.html',
    requires: 'files.view',
    label: 'Files',
    icon: 'fe fe-folder',
    order: 50,
    group: 'System',
    maxBody: 16 * 1024 * 1024)
class FilesPage extends AdminPage {
  String get _folder => Storage.normalize(get('f') ?? '/');

  /// id from the form; null = garbage in the parameter (400, not 500).
  int? get _id => int.tryParse(get('id') ?? '');

  /// Multipart field of the upload input in `files.html`.
  static const uploadField = 'files';

  String _reason(FormatException e) => e is StorageException ? t(e.key, e.params) : e.message;

  bool _back(String k, {String type = 'success'}) =>
      back('/admin/files?f=${Uri.encodeComponent(_folder)}', message: k, type: type);

  @Action('new_folder')
  Future<bool> newFolder() async {
    if (!can('files.folders')) return missingPermission('files.folders');
    try {
      await Storage.createFolder(_folder, get('name') ?? '', login, context.service);
      return _back(t('ignis.msg.files.folder_created'));
    } on FormatException catch (e) {
      return _back(_reason(e), type: 'danger');
    }
  }

  @Action('folder_delete')
  Future<bool> deleteFolder() async {
    if (!can('files.folders')) return missingPermission('files.folders');
    try {
      final id = _id;
      if (id == null) return badRequest();
      await Storage.deleteFolder(id, context.service);
      return _back(t('ignis.msg.files.folder_deleted'));
    } on FormatException catch (e) {
      return _back(_reason(e), type: 'danger');
    }
  }

  @Action('upload')
  Future<bool> upload() async {
    if (!can('files.upload')) return missingPermission('files.upload');
    final toUpload = files.where((p) => p.field == uploadField).toList();
    if (toUpload.isEmpty) return _back(t('ignis.msg.files.none_selected'), type: 'danger');

    var added = 0, duplicates = 0;
    for (final f in toUpload) {
      try {
        final (_, duplicate) = await Storage.upload(
          path: _folder,
          name: f.safeName(),
          type: f.type,
          data: f.data,
          actor: login,
          service: context.service,
        );
        duplicate ? duplicates++ : added++;
      } on FormatException catch (e) {
        return _back(_reason(e), type: 'danger'); // e.g. the service's space limit
      }
    }
    return _back(duplicates == 0
        ? t('ignis.msg.files.uploaded', {'n': added})
        : t('ignis.msg.files.uploaded_dupes', {'n': added, 'dupes': duplicates}));
  }

  @Action('file_delete')
  Future<bool> deleteFile() async {
    if (!can('files.delete')) return missingPermission('files.delete');
    final id = _id;
    if (id == null) return badRequest();
    try {
      await Storage.deleteFile(id, context.service);
    } catch (e) {
      stderr.writeln('storage: could not delete file $id: $e');
      return _back(t('ignis.msg.files.delete_failed'), type: 'danger');
    }
    return _back(t('ignis.msg.files.deleted'));
  }

  @Action('file_save')
  Future<bool> saveFile() async {
    if (!can('files.edit')) return missingPermission('files.edit');
    final id = _id;
    if (id == null) return badRequest();
    await Storage.rename(id, get('name') ?? '', get('description') ?? '', context.service);
    final target = get('move_to') ?? '';
    if (target.isNotEmpty && Storage.normalize(target) != _folder) {
      try {
        await Storage.move(id, target, context.service);
      } on FormatException catch (e) {
        return _back(t('ignis.msg.files.saved_not_moved', {'reason': _reason(e)}), type: 'danger');
      }
      return _back(t('ignis.msg.files.saved_moved', {'path': Storage.normalize(target)}));
    }
    return _back(t('ignis.msg.files.saved'));
  }

  @override
  Future<void> insertData() async {
    await sharedData();
    final folder = _folder;

    put('folder', folder);
    put('at_root', folder == '/');
    put('breadcrumbs', [
      for (final (name, path) in Storage.breadcrumbs(folder, root: t('ignis.files.title'))) {'name': name, 'path': path}
    ]);
    put('parent', folder == '/'
        ? '/'
        : Storage.normalize(folder.substring(0, folder.lastIndexOf('/', folder.length - 2) + 1)));

    put('folders', [
      for (final f in await Storage.subfolders(folder, context.service))
        {
          'id': f.id, 'name': f.name, 'path': f.path,
          'file_count': f.fileCount, 'subfolder_count': f.subfolderCount, 'empty': f.isEmpty,
        }
    ]);
    final l = Listing.fromPage(this, sorting: const {'date': 'uploaded_at'}, defaults: 'date');
    final total = await Storage.fileCount(folder, context.service);
    if (l.outOfRange(total)) return;
    put('listing', l.model(total));
    put('file_list', [
      for (final p in await Storage.files(folder, context.service, limit: l.onPage, from: l.offset))
        {
          'id': p.id, 'key': p.key, 'name': p.name, 'type': p.type,
          'size': p.sizeReadable, 'image': p.isImage, 'description': p.description,
          'uploaded_by': p.uploaded_by, 'uploaded_at': p.uploaded_at.split('T').first,
          'url': '/files/${p.key}',
        }
    ]);
    put('paths', await Storage.allPaths(context.service));
    put('can_upload', can('files.upload'));
    put('can_edit', can('files.edit'));
    put('can_delete', can('files.delete'));
    put('can_folders', can('files.folders'));

    final (count, bytes, folderCount) = await Storage.stats(context.service);
    put('stat_files', count);
    put('stat_folders', folderCount);
    put('stat_size', bytes < 1024 * 1024
        ? '${(bytes / 1024).toStringAsFixed(0)} KB'
        : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB');
  }
}

/// Serving content. The route is PUBLIC, because files end up in page content,
/// but the object key is a random 32 hex chars — the address cannot be guessed or
/// derived from the previous one. It gives no access to the file list.
@Page('/files', noDb: true)
class ServeFilePage extends PageEngine {
  @override
  Future<bool> doBeforeProcess() async {
    // the key arrives as ?k=YYYY/MM/hex.ext — see the path rewrite in ignis.dart
    final key = get('k') ?? '';
    if (!allowed(key, context.service)) {
      return notFound(); // JSON — this is a resource route, not a page for a human
    }
    try {
      // a stream straight from storage to the client — a 5 MB image does not land in node RAM
      final stream = await Storage.read(key);
      status = 200;
      final type = _typeFromKey(key);
      header('Content-Type', type);
      // the key does not change, but a deleted file must not live in the browser and CDN cache for a year
      header('Cache-Control', 'public, max-age=86400');
      if (!type.startsWith('image/')) header('Content-Disposition', 'attachment');
      // A user file never runs a script in the panel origin: SVG/PDF/HTML
      // opened directly get a sandbox (in <img> there are no scripts anyway).
      header('Content-Security-Policy', 'sandbox');
      saveStream(stream);
      return false;
    } catch (_) {
      return notFound();
    }
  }

  /// Object key served under the domain of service [service]: the `t<service>/` prefix must match,
  /// otherwise customer N's file could be downloaded from any other domain (also after N is disabled —
  /// a disabled domain gets 402 earlier). Keys from before multi-domain (without a prefix)
  /// belonged to the platform, so only there.
  static bool allowed(String key, int service) {
    final m = _key.firstMatch(key);
    if (m == null) return false;
    return m[1] == null ? service == 0 : int.tryParse(m[1]!) == service;
  }

  static final _key = RegExp(r'^(?:t(\d+)/)?\d{4}/\d{2}/[0-9a-f]{32}\.[A-Za-z0-9]{1,8}$');

  static String _typeFromKey(String k) => switch (k.split('.').last.toLowerCase()) {
        'png' => 'image/png',
        'jpg' || 'jpeg' => 'image/jpeg',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        'svg' => 'image/svg+xml',
        'pdf' => 'application/pdf',
        'mp4' => 'video/mp4',
        'zip' => 'application/zip',
        'txt' => 'text/plain; charset=utf-8',
        'json' => 'application/json',
        _ => 'application/octet-stream',
      };
}
