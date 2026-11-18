// The upload input of the files template and FilesPage read the same multipart field.
import 'dart:io';

import 'package:ignis/pages/files_page.dart';

void check(String description, bool ok) {
  if (!ok) throw StateError('FAILED: $description');
  print('  ok — $description');
}

void main() {
  final html = File('templates/files.html').readAsStringSync();
  check('template input name = FilesPage.uploadField',
      html.contains('<input type="file" name="${FilesPage.uploadField}"'));
}
