// ============================================================================
//  pages.dart — BARREL wszystkich stron
// ----------------------------------------------------------------------------
//  ⚠️ CRUCIAL for reflection: dart:mirrors sees only REACHABLE classes
//  (loaded into the program). That is why EVERY page class has to be imported here,
//  and this file imported in bin/server.dart. Without it the VM drops an unused
//  class and registry.build() will not find it.
// ============================================================================

// panel administracyjny
export 'pages/dashboard_page.dart';
export 'pages/settings_page.dart';
export 'pages/permissions_page.dart';

export 'pages/login_page.dart';
export 'pages/logout_page.dart';
export 'pages/files_page.dart';
export 'pages/health_page.dart';
export 'pages/audit_log_page.dart';
export 'pages/account_page.dart';
