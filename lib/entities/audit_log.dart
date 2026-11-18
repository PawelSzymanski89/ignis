// ============================================================================
//  audit_log.dart — the trail of whatever anyone changed in the panel
// ----------------------------------------------------------------------------
//  A multi-tenant panel without an audit log is not ready for production: the platform
//  owner can disable someone's site, change a plan and change a customer account
//  password, and a customer can delete data or an employee account. Without a record
//  there is no answer to "who did this and when", and that is the first
//  question after every failure and with every complaint.
//
//  An entry is created AUTOMATICALLY for every panel action (`engine.dart`), so
//  a new page is covered by the audit log without adding anything. Parameters
//  are stored filtered — passwords, tokens and certificates must NOT
//  land in the audit log, because that would turn the audit into a leak.
// ============================================================================

import '../engine/annotations.dart';

@Entity('audit_log')
class AuditLogEntry {
  int? id;
  /// Service in whose context the action ran. 0 = platform panel.
  int service = 0;
  /// Account that performed the action.
  String actor = '';
  /// Panel page address, e.g. `/admin/services`.
  String location = '';
  /// Action name from `@Action`, e.g. `user_add`.
  String action = '';
  /// Form parameters after removing secrets — enough to reconstruct
  /// what the action was about (id, login, name), without confidential values.
  String detail = '';
  /// Service the action CONCERNED, when different from `service` — this is how
  /// platform operations on a customer's site show up. 0 = the same or not applicable.
  int target = 0;
  String ip = '';
  String occurred_at = '';
  /// `ok`, `denied` (no permission, bad login/code, lock) or `error` (the action threw).
  String result = 'ok';
}
