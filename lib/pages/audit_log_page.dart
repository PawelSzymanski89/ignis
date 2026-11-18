// ============================================================================
//  audit_log_page.dart — "/admin/audit-log": the trail of panel operations
// ----------------------------------------------------------------------------
//  Answers the question asked after every failure and with every complaint:
//  who changed this and when. Entries are created automatically for every panel
//  action (`engine.dart`), so the list is complete without anyone remembering it.
//
//  A customer sees its own entries AND what the platform did at it — transparency
//  works both ways, and it is not politeness but a condition of trust in a
//  system in which someone from outside has access to its data.
//  The audit log cannot be deleted or edited from the panel: read only.
// ============================================================================

import '../engine/admin_page.dart';
import '../engine/annotations.dart';
import '../engine/audit_log.dart';

@Page('/admin/audit-log',
    template: 'audit_log.html',
    requires: 'audit_log.view',
    label: 'Audit log',
    icon: 'fe fe-list',
    order: 80,
    group: 'System')
class AuditLogPage extends AdminPage {
  static const _perPage = 50;

  @override
  Future<void> insertData() async {
    await sharedData();
    final all = context.platform;
    final actor = (get('author') ?? '').trim();
    final search = (get('q') ?? '').trim();
    final before = int.tryParse(get('before') ?? '');
    final after = before == null ? int.tryParse(get('after') ?? '') : null;

    // one more, to know whether there is a next page — no count(*) over the whole table
    final fetched = await AuditLog.list(context.service,
        all: all, actor: actor, search: search, limit: _perPage + 1, before: before, after: after);
    final more = fetched.length > _perPage;
    // with `after` the extra one is the newest (first), otherwise the oldest (last)
    final entries = after != null && more ? fetched.sublist(1) : fetched.take(_perPage).toList();

    put('entries', [
      for (final w in entries)
        {
          'actor': w.actor, 'location': w.location, 'action': w.action,
          'detail': w.detail, 'ip': w.ip, 'date': w.date,
          'target_name': w.targetName, 'result': w.result,
          // a platform entry seen at a customer: AuditLog gives "support" and an empty IP instead of the operator login
          'from_platform': w.service == 0 && w.target != 0,
        }
    ]);
    put('authors', await AuditLog.authors(context.service, all: all));
    put('actor', actor);
    put('q', search);
    String address(String key, int id) => '?${Uri(queryParameters: {
          key: '$id',
          if (actor.isNotEmpty) 'author': actor,
          if (search.isNotEmpty) 'q': search,
        }).query}';
    final newer = entries.isNotEmpty && (before != null || (after != null && more));
    final older = entries.isNotEmpty && (after != null || more);
    put('newer', newer ? address('after', entries.first.id) : '');
    put('older', older ? address('before', entries.last.id) : '');
    put('platform_sees_all', all);
  }
}
