// ============================================================================
//  customer_page.dart — a front page only for a signed-in customer account
// ----------------------------------------------------------------------------
//  Session from the CustomerAccounts.cookie cookie (never from the panel session). No session →
//  redirect to `@Page(redirectIfNotAbleToSee:)` with `?next=<route>`.
//  What the customer sees after sign-in is decided by the app (the `client` getter).
// ============================================================================

import 'customer_accounts.dart';
import 'page_engine.dart';

abstract class CustomerPage extends PageEngine {
  CustomerSession? _client;

  /// The signed-in customer — always non-null after doBeforeProcess.
  CustomerSession get client => _client!;

  static String toLogin(String login, String route) =>
      '$login?next=${Uri.encodeQueryComponent(route)}';

  @override
  Future<bool> doBeforeProcess() async {
    _client = await CustomerAccounts.session(cookie(CustomerAccounts.cookie), context.service);
    if (_client != null) return true;
    redirect(toLogin(meta.redirectIfNotAbleToSee, meta.route));
    return false;
  }

  /// Redirect with a signed message — the same format as `AdminPage.back`
  /// (signed with the node key, so a forged `?flash=` in a link is not shown).
  bool back(String url, {String? message, String type = 'success'}) {
    redirect(message == null ? url : '$url${url.contains('?') ? '&' : '?'}${flashInUrl(message, type)}');
    return false;
  }

  /// Message from [back] for the template (`message`, `message_type`), if the signature matches.
  void messageFromUrl() {
    final f = flashFromUrl();
    if (f == null) return;
    put('message', f.$2);
    put('message_type', f.$1);
  }
}
