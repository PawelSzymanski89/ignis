// ============================================================================
//  files.dart — folder structure and file references
// ----------------------------------------------------------------------------
//  The bytes live in MinIO, but EVERYTHING we know about them sits in Postgres:
//  where the file is in the tree, what it is called, who uploaded it, how big it is, what its
//  digest is. So listing a folder is one SQL query, not a storage
//  scan — and we lose neither names nor structure when storage changes.
//
//  The MinIO object key is DELIBERATELY different from the file name: it is `year/month/uuid.ext`.
//  A human-given name can be dangerous, repetitive and changing, while the key
//  must be stable and unique. Renaming in the panel does not touch the object in storage.
// ============================================================================

import '../engine/annotations.dart';

/// Folder. The tree is kept in TWO ways at once: `parent` (for moving
/// and deleting a subtree) and `path` (for listing and breadcrumbs without recursion).
@Entity('folders', unique: [
  ['path', 'service']
])
class Folder {
  int? id;
  /// Service the folder belongs to (0 = platform).
  int service = 0;
  String name = '';
  /// Full path with leading and trailing slashes: `/`, `/images/`, `/images/banners/`.
  String path = '/';
  /// 0 = root (the root folder has no row in the table).
  int parent = 0;
  String created_by = '';
  String created_at = '';
}

/// File reference. One row = one object in MinIO.
@Entity('files', unique: [
  ['key']
])
class FileRecord {
  int? id;
  /// Service the file belongs to (0 = platform).
  int service = 0;
  /// MinIO object key — stable, never changed.
  String key = '';
  /// Name shown to humans; it can be changed without touching storage.
  String name = '';
  /// Folder the file is in (the same convention as Folder.path).
  String path = '/';
  String type = 'application/octet-stream';
  int size = 0;
  /// SHA-256 of the content — detects uploading the same file a second time.
  String hash = '';
  String uploaded_by = '';
  String uploaded_at = '';
  /// Description/alt — useful when inserting images into content.
  String description = '';
}
