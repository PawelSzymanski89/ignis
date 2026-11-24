// Storage.allowed / Storage.read: plik z magazynu tylko pod domeną usługi z prefiksu klucza — bez bazy i MinIO.
import 'package:ignis/engine/storage.dart';

void check(String description, bool condition) {
  if (!condition) throw AssertionError('NOT PASSED: $description');
  print('  ok — $description');
}

Future<void> main() async {
  const h = '0123456789abcdef0123456789abcdef';
  check('własna usługa', Storage.allowed('t3/2026/08/$h.jpg', 3));
  check('cudza usługa — nie', !Storage.allowed('t3/2026/08/$h.jpg', 4));
  check('t3 nie pasuje do t33', !Storage.allowed('t33/2026/08/$h.jpg', 3));
  check('klucz usługi z domeny platformy — nie', !Storage.allowed('t3/2026/08/$h.jpg', 0));
  check('platforma: t0 i stary klucz bez prefiksu',
      Storage.allowed('t0/2026/08/$h.png', 0) && Storage.allowed('2025/01/$h.png', 0));
  check('stary klucz z domeny usługi — nie', !Storage.allowed('2025/01/$h.png', 3));
  check('zły format — nie', !Storage.allowed('t3/../x', 3) && !Storage.allowed('', 0));
  // SEC-040.3: Storage.read refuses tenant A's key for service B before touching storage
  Object? refused;
  try {
    await Storage.read('t3/2026/08/$h.jpg', 4);
  } catch (e) {
    refused = e;
  }
  check('Storage.read: key of service 3 with service 4 → StorageException ($refused)', refused is StorageException);
}
