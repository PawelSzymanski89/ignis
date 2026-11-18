// ============================================================================
//  tenant.dart — services (tenants) and their domains
// ----------------------------------------------------------------------------
//  One engine serves many independent sites. "Service" = tenant.
//  Each has its own accounts, files, configuration and data, and does not see the others'.
//
//  CONVENTION: `service = 0` means PLATFORM (our accounts, they belong to no
//  customer). Zero instead of NULL, because `= 0` never yields NULL, and one
//  forgotten `IS NULL` in a condition is a silent leak. A platform account is recognized
//  explicitly by `service == 0`, not by a missing value.
// ============================================================================

import '../engine/annotations.dart';

/// Service (tenant) running on the engine.
@Entity('services', unique: [
  ['slug']
])
class Service {
  int? id;
  /// Name shown in the platform panel and in the site title.
  String name = '';
  /// Identifier in the address: `demo` → demo.<domain from IGNIS_DOMAINS>.
  String slug = '';
  /// A disabled service does not answer on its domains, but no data is lost.
  bool active = true;
  /// Storage space limit (MB). 0 = no limit.
  int limit_mb = 500;
  String created_at = '';
  /// Who created it — the platform account login.
  String created_by = '';
}

/// Domain pointing at a service. One service can have many of them
/// (own domain + subdomain in the system domain).
@Entity('domains', unique: [
  ['domain']
])
class Domain {
  int? id;
  int service = 0;
  /// No protocol and no `admin.` — just the core: `example.com`.
  /// This service's panel lives under `admin.example.com`, the front under `example.com`.
  String domain = '';
  /// Primary domain of the service — used in links in e-mails and in redirects.
  bool is_primary = false;
  String added_at = '';
}
