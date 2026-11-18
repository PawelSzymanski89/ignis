// SerwujPlikPage.dozwolony: plik z magazynu tylko pod domeną usługi z prefiksu klucza — bez bazy i MinIO.
import 'package:ignis/pages/files_page.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

void main() {
  const h = '0123456789abcdef0123456789abcdef';
  check('własna usługa', ServeFilePage.allowed('t3/2026/08/$h.jpg', 3));
  check('cudza usługa — nie', !ServeFilePage.allowed('t3/2026/08/$h.jpg', 4));
  check('t3 nie pasuje do t33', !ServeFilePage.allowed('t33/2026/08/$h.jpg', 3));
  check('klucz usługi z domeny platformy — nie', !ServeFilePage.allowed('t3/2026/08/$h.jpg', 0));
  check('platforma: t0 i stary klucz bez prefiksu',
      ServeFilePage.allowed('t0/2026/08/$h.png', 0) && ServeFilePage.allowed('2025/01/$h.png', 0));
  check('stary klucz z domeny usługi — nie', !ServeFilePage.allowed('2025/01/$h.png', 3));
  check('zły format — nie', !ServeFilePage.allowed('t3/../x', 3) && !ServeFilePage.allowed('', 0));
}
