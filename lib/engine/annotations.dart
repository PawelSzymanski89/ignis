// ============================================================================
//  annotations.dart — Ignis framework annotations
// ----------------------------------------------------------------------------
//  @Page sits on a page class and declares:
//    - the address (route) the page answers,
//    - the template it renders with,
//    - where to redirect when the user may not see it (isAbleToSee=false),
//    - which permission it requires.
//
//  Annotations must be `const`: the registry builder evaluates them at build time.
// ============================================================================

/// Declares a class as an Ignis page. The engine (registry.dart) scans all classes
/// with this annotation from the generated registry (`Ignis.start(registry:)`) and builds the route table from them.
class Page {
  /// URL path the page answers, e.g. `/`, `/login`, `/dashboard`.
  /// A `{name}` segment (e.g. `/v1/profiles/{id}`) matches one non-empty segment;
  /// its value goes to the page parameters (`get('id')`). Exact routes take precedence.
  final String route;

  /// Template file name in the `templates/` directory, e.g. `home.html`.
  /// The render fires only when the page reaches insertData().
  final String template;

  /// Where to redirect when isAbleToSee() returns false.
  /// The sign-in page by default.
  final String redirectIfNotAbleToSee;

  /// Required permission in the `section.action` convention (e.g. 'settings.view').
  /// Enforced by AdminPage.isAbleToSee(); the menu is filtered by the same requirement.
  final String? requires;

  /// Label in the side menu. `null` = page outside the menu (login, actions, API).
  final String? label;

  /// Menu item icon — Feather (`fe fe-*`), the theme's convention.
  final String? icon;

  /// Order in the menu (ascending). Values go in tens within a group,
  /// so inserting a page in the middle does not require renumbering its neighbours.
  final int order;

  /// Section heading in the side menu. `null` = item in the default section (at
  /// the very top). Without groups the menu was a flat list of twenty items, in which
  /// platform matters stood above everyday work.
  final String? group;

  /// Technical route: works REGARDLESS of the domain in the request. The load balancer
  /// health check knocks on the node IP (Host: 127.0.0.1), so the health probe must not
  /// require a resolved service — otherwise the first tenant-aware deploy
  /// brings down the whole cluster, because Caddy considers every node dead.
  /// Answers only loopback and `IGNIS_TRUSTED_PROXIES` without `X-Forwarded-For` (everyone else: 404).
  final bool technical;

  /// The page does not use the database through [Db.connect] in the request context (static files from storage,
  /// health probe with its own query) — the engine takes no pool connection for it,
  /// so slow clients of such a route cannot exhaust the pool (PERF-A-1).
  final bool noDb;


  /// Page only for the platform panel (managing customers).
  /// In a service panel it neither appears in the menu NOR can be entered.
  final bool platformOnly;


  /// Page available also to an account that must change its initial password. Apart from it
  /// the panel is closed to such an account — this must be exactly the password
  /// change page and sign-out, nothing more.
  final bool exemptFromPasswordChange;

  /// API route for non-browser clients (SDK, mobile apps):
  /// no CSRF, no form parsing; raw body in `PageEngine.body`
  /// (up to 2 MB on the wire, gzip up to 8 MB inflated). Errors as a bare status code.
  /// Without CSRF it must not authenticate by cookie: on an `AdminPage`/`CustomerPage` subclass the node refuses to start,
  /// and the page never sees the session, customer-session or CSRF cookie nor the `Cookie` header.
  final bool api;

  /// Allowed HTTP methods (e.g. `['POST']`); another method → 405 with an `Allow` header.
  /// Empty = all.
  final List<String> methods;

  /// Body limit in bytes: API routes (on the wire and after gzip inflation; null = 2 MB / 8 MB) and the page's
  /// multipart form (raw request bytes). A page without `maxBody` does NOT accept multipart — it gets 413.
  /// Large limits (symbol files, exports) keep the whole body in memory — set them deliberately.
  final int? maxBody;

  /// The API route accepts a binary body: bytes in `PageEngine.bodyBytes`, `body` stays empty.
  final bool binary;

  /// API route called from a browser on another domain: the engine answers the `OPTIONS` preflight itself (204, methods from
  /// [methods], headers from `Access-Control-Request-Headers`), and the page decides whether to let a given `Origin` in
  /// ([PageEngine.allowOrigin]) — without it the browser will not hand the response to the script.
  ///
  /// REQUIREMENT: without [Engine.preflightOrigin] the preflight echoes every Origin, so such a route must (1) call
  /// `allowOrigin` itself before responding and (2) not authenticate by cookie — only by a token/key in a header.
  final bool cors;

  const Page(
    this.route, {
    this.template = '', // optional — API pages return JSON, no render
    this.redirectIfNotAbleToSee = '/admin/login',
    this.requires,
    this.label,
    this.icon,
    this.order = 100,
    this.group,
    this.platformOnly = false,
    this.technical = false,
    this.noDb = false,
    this.exemptFromPasswordChange = false,
    this.api = false,
    this.methods = const [],
    this.maxBody,
    this.binary = false,
    this.cors = false,
  });
}

/// The @Synced marker. Used as a constant instance (like @override), so it can be
/// written WITHOUT parentheses: `@Synced bool taskFlag;`.
class SyncedMarker {
  const SyncedMarker();
}

/// Marker @SessionSynced.
class SessionSyncedMarker {
  const SessionSyncedMarker();
}

/// A field shared by the WHOLE SYSTEM (per-system). One node changes it → everyone
/// sees it, durably (as long as the system lives / until another node overwrites it).
/// Redis: `synced:<Class>.<field>` (no TTL).
const Synced = SyncedMarker();

/// Like @Synced, but PER-USER (per-session): under the session token, TTL = session lifetime
/// → gone when the session expires. Redis: `ssync:<sha256(token)>:<Class>.<field>`.
const SessionSynced = SessionSyncedMarker();

/// Domain entity — mapped to a Postgres table through the generated registry (`lib/ignis_registry.g.dart`).
/// Class fields = columns (name 1:1). Primary key: the `id` field or the one given in `pk`.
/// e.g. `@Entity('notes') class Note { int? id; String text = ''; }`
class Entity {
  final String table;

  /// Primary key column. `id` by default (project convention).
  final String pk;

  /// Unique constraints — each list is one UNIQUE (columns together).
  /// This is how join tables are modelled: @Entity('user_packages', pk: 'id',
  /// unique: [['username','package_id']]).
  final List<List<String>> unique;

  const Entity(this.table, {this.pk = 'id', this.unique = const []});
}

/// Cached entity — copied to Redis (key `entity:<Type>:<id>`),
/// so every node sees the same. ttl=0 → no expiry (lives as long as the system).
class Cached {
  final int ttl;
  const Cached({this.ttl = 0});
}

/// Page action method. Runs BEFORE insertData when the request (query
/// OR body) has `triggerAction=<name>`. Several methods may share a name
/// — then all of them run (in declaration order).
/// Returns bool: true = keep rendering; false = the action handled the response itself
/// (e.g. redirect/JSON in the output stream) → render skipped (like the other gates).
/// e.g. `@Action('delete') Future<bool> deleteItem() { ...; redirect('/x'); return false; }`
class Action {
  final String name;
  const Action(this.name);
}
