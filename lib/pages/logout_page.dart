// ============================================================================
//  logout_page.dart — sign-out "/admin/logout"
// ----------------------------------------------------------------------------
//  Destroys the session in Redis, deletes the cookie and redirects to /login.
//  All work in doBeforeProcess (before auth) — we return false (no render).
// ============================================================================

import '../engine/annotations.dart';
import '../engine/page_engine.dart';
import '../engine/session.dart';

@Page('/admin/logout', template: 'login.html')
class LogoutPage extends PageEngine {
  @override
  Future<bool> doBeforeProcess() async {
    // POST only (a form with the CSRF token in the menu). With GET anyone could sign
    // the user out with a foreign <img src="/admin/logout">.
    if (method != 'POST') {
      redirect('/admin');
      return false;
    }
    await Sessions.destroy(cookie(Sessions.cookieName)); // remove the session from Redis
    setCookie(Sessions.cookieName, '', maxAge: 0);        // delete the cookie
    redirect('/admin/login');
    return false; // I handled the response myself (redirect), no render
  }
}

/// Old sign-out route — a redirect, so bookmarks and open tabs from before
/// the panel moved under /admin do not end in a 404.
@Page('/logout')
class LegacyLogout extends PageEngine {
  @override
  bool doBeforeProcess() {
    redirect('/admin/logout');
    return false;
  }
}
