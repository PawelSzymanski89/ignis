// ============================================================================
//  upload.dart — receiving files from a form (multipart/form-data)
// ----------------------------------------------------------------------------
//  dart:io parses only x-www-form-urlencoded, so upload needs its own
//  step. We use `package:mime` (by the Dart team) — it splits the stream into parts,
//  and we turn them into text fields and files.
//
//  SECURITY:
//   • twardy limit rozmiaru — inaczej jeden request zapycha RAM node'a,
//   • a file name NEVER reaches the disk in the form sent by the client
//     (see safeName) — `../../etc/cron.d/x` would be an invitation,
//   • the type comes from the part header, but the caller must check it anyway.
// ============================================================================

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mime/mime.dart';

class UploadedFile {
  UploadedFile(this.field, this.name, this.type, this.data);
  final String field;      // name= from the form
  final String name;     // original name (for display, NOT for storage)
  final String type;       // Content-Type of the part
  final List<int> data;

  int get size => data.length;
  String get text => utf8.decode(data);

  /// A name safe for storing on disk: no paths, no control characters,
  /// trimmed. The extension is kept, because the Content-Type is derived from it.
  String safeName() {
    final db = name.split(RegExp(r'[/\\]')).last;
    final clean = db
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^[.-]+'), ''); // hidden files and ".." are dropped
    return clean.isEmpty ? 'file' : (clean.length > 100 ? clean.substring(0, 100) : clean);
  }
}

class UploadResult {
  UploadResult(this.fields, this.files);
  final Map<String, String> fields;
  final List<UploadedFile> files;
}

class Upload {
  /// Whether the request is multipart at all.
  static bool isMultipart(HttpRequest req) =>
      (req.headers.contentType?.mimeType ?? '') == 'multipart/form-data';

  /// Most parts in one form and the longest field name — thousands of empty
  /// parts with long `name="…"` inflated the field map beyond the content limit.
  static const maxParts = 200, maxFieldName = 256;

  /// Splits a multipart into fields and files. [byteLimit] counts the RAW request bytes
  /// (part headers, boundaries and content), incrementally — we stop midway.
  /// Throws [UploadTooLarge] when over the limit, [FormatException] on a malformed body.
  static Future<UploadResult> receive(Stream<List<int>> req, String? boundary, {required int byteLimit}) async {
    if (boundary == null) throw const FormatException('No boundary in multipart/form-data');

    final fields = <String, String>{};
    final files = <UploadedFile>[];
    var total = 0, parts = 0;
    final computed = req.map((k) {
      total += k.length;
      if (total > byteLimit) throw UploadTooLarge(byteLimit);
      return k;
    });

    await for (final part in MimeMultipartTransformer(boundary).bind(computed)) {
      if (++parts > maxParts) throw const FormatException('Too many form parts');
      final disposition = part.headers['content-disposition'] ?? '';
      final fieldName = _param(disposition, 'name') ?? '';
      final fileName = _param(disposition, 'filename');
      if (fieldName.length > maxFieldName) throw const FormatException('Field name too long');

      // BytesBuilder keeps bytes compact; a growable List<int> would take 8 B per byte
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in part) {
        buffer.add(chunk);
      }

      if (fileName == null) {
        fields[fieldName] = utf8.decode(buffer.takeBytes(), allowMalformed: true);
      } else if (fileName.isNotEmpty && buffer.isNotEmpty) {
        files.add(UploadedFile(fieldName, fileName,
            part.headers['content-type'] ?? 'application/octet-stream', buffer.takeBytes()));
      }
    }
    return UploadResult(fields, files);
  }

  static String? _param(String header, String key) {
    final m = RegExp('$key="([^"]*)"').firstMatch(header);
    return m?.group(1);
  }
}

class UploadTooLarge implements Exception {
  const UploadTooLarge(this.limit);
  final int limit;
  @override
  String toString() => limit < 1024 * 1024
      ? 'Form exceeds the limit of ${(limit / 1024).round()} KB'
      : 'File exceeds the limit of ${(limit / 1024 / 1024).round()} MB';
}
