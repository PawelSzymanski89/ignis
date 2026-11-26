# Changelog

## 0.5.0 — Unreleased

### Added

- Background jobs: `Redis.runExclusive(name, ttl, body)` — `lock:<name>` with a per-run token, keep-alive every
  ttl/3, owner-only release; `body` gets `stillOwner()` (false once the lock is lost). `Ignis.every(name, interval, ttl,
  body)` runs it on a timer (errors logged, no overlap); `Ignis.stopJobs()` runs at node shutdown.
  `Redis.confirmExclusive(name)` checks ownership in Redis right now (for long runs, before each batch).
  `Redis.abandonExclusive({wait})` turns `stillOwner()` false for active runs and waits for them; node shutdown
  calls it before `Redis.releaseLocks`, so a run still going is not doubled by another node taking its lock.
- RLS by an app tenant column: `@Entity(..., tenantColumn: 'tenant')` (text or int) and `Db.asTenant(tenant, body)`
  (`ignis.tenant`, local to one transaction). No tenant = 0 rows; only the system context sees all; `Schema.checkRls`
  covers the new tables. `EntityMeta` gains an optional `tenantColumn` (regenerate the registry). Entities without it
  are unchanged.
- `Db.bindTenant(tenant)` binds an app tenant to the current request transaction after authentication (request pages
  run inside `Db.inContext`, where `Db.asTenant` throws); one-way, survives `Db.release`/`commit`.

### Changed (breaking)

- A stale `lib/ignis_registry.g.dart` (lib/ changed since the last `build_runner build`) now stops a JIT start with a
  `StateError` instead of one warning. `IGNIS_ALLOW_STALE_REGISTRY=1` restores the old warning-only behaviour. AOT
  binaries are unchanged (no sources, no check). `Ignis.resolveRegistry` gains an optional `env`.

### Fixed

- A failed permission/settings cache invalidation (Redis blip) is logged and retried in the background until it goes
  through, instead of leaving a revoked permission cached for up to 15 min. Other swallowed Redis errors in
  `Permissions` are logged to stderr (at most once a minute per kind).
- `/health` writes its `health:<node>` probe with a 60 s TTL instead of a key that never expires.

## 0.4.4 — 2026-11-26

### Fixed

- The application seed (`Ignis.start(seed: ...)`) now runs **inside** the start-up advisory lock, together with
  `Schema.sync()` and the engine seed. Before, N nodes starting at once ran it concurrently (index builds, data
  migrations), and a node could serve traffic before another node's app seed finished.
- Customer password reset: the per-IP limit (`rl:reset:ip:…`) is keyed by `rateLimitAddress` (IPv6 /64), like every
  other limit — rotating addresses within one /64 no longer gets around it.

### Documentation

- SECURITY.md → [Second factor](SECURITY.md#second-factor): how to enable TOTP for the platform administrator, what to
  do after the first start (`IGNIS_ADMIN_PASS` is used only when the `users` table is empty — remove it from the env
  file afterwards) and how to recover a lost phone from the console.

## 0.4.3 — 2026-11-25

- `timezone` ^0.11.2 (tzdata 2026e); `TimeZone.offset` is now a `Duration` — ignis API unchanged.
- Dependencies: `postgres` ^3.6.0 (3.7.0 locked), `jinja` ^0.7.2, `crypto` ^3.0.8, `mime` ^2.1.0; CI: `actions/checkout` v7.0.1, `actions/setup-node` v7.1.0.

## 0.4.2 — 2026-11-25

### Added

- `Orm.save(entity, only: [...], ifUnchanged: stamp)` and `Orm.upsert(..., only: [...], ifUnchanged: stamp)`: optimistic
  lock for edits of the same row from two stale copies (two users, the same form). `Orm.stamp(entity, only)` (`''` for
  "no row") goes into a hidden form field; the save locks just that row (`SELECT … FOR UPDATE`) and throws
  `StaleEntity` without writing when the [only] columns changed, the row was deleted, or (`''`) someone created it
  meanwhile. Columns outside `only:` (counters, worker state) are not part of the stamp.

## 0.4.1 — 2026-11-25

### Added

- `Redis.delIfEqual(key, value)` and `Redis.expireIfEqual(key, value, seconds)`: compare-and-delete /
  compare-and-expire, so a job lock whose TTL ran out and was taken by another node is not dropped or prolonged by
  the late first owner. Use a value unique per run (node + random token). `releaseLocks(node)` also clears
  `node:<token>` values.
- `Orm.save(entity, only: [...])` and `Orm.upsert(entity, only: [...])` write just the listed columns, so a copy
  read before long work does not overwrite columns another writer changed meanwhile (an unknown column throws
  `ArgumentError`; `upsert` still inserts a new row whole).

### Documentation

- README → [Running a cluster](README.md#-running-a-cluster): topology, per-node settings, schema, rolling deploy,
  proxy, checklist.

## 0.4.0 — 2026-11-24

Security hardening round SEC-040 (details in [SECURITY.md → 0.4.0](SECURITY.md#040)).

### Breaking

- **`api: true` routes no longer receive session/CSRF cookies or the `Cookie` header**: `cookie()` returns null
  for `__Host-ignis_session`, `__Host-ignis_customer` and `__Host-ignis_csrf`, and `requestHeader('cookie')` is
  null. Authenticate API routes by a token in a header.
- **`Storage.read(key, service)` requires the service**: a key without the `t<service>/` prefix throws
  `StorageException`. `ServeFilePage.allowed` moved to `Storage.allowed`.
- A session or 2FA value in the 0.2.0 plain-login (non-JSON) format is no longer accepted.

### Changed

- An elevated block whose context restore fails leaves the transaction fail-closed (later queries throw).
- `/assets/` sends `immutable` only when `?v=` matches the served file's digest, otherwise `no-cache`.
- Start-up warns when `IGNIS_NODE` is unset or a remote Redis has an empty `IGNIS_REDIS_PASS`; session Redis
  failures are logged.
- `tool/runtime_role.sql` takes passwords from psql variables (`-v owner_pass=… -v rt_pass=…`).
- CI also runs weekly (Monday 06:00 UTC), so the `scan` job catches new advisories.

## 0.3.0 — 2026-11-20

Pages and entities now come from a registry generated at build time by a builder that ships in `ignis`, instead
of a runtime scan — so a node runs under `dart run` and as one native binary (`dart compile exe`). Why:
`dart:mirrors` is deprecated in Dart 3.14 and unavailable to AOT and Flutter — details in
[README → Why no `dart:mirrors`](README.md#why-no-dartmirrors).

### Breaking

- **`Ignis.start(registry:)` is required.** Without it the node stops at start-up with a `StateError` that
  lists the three upgrade steps below.
- Every page and entity class must live under `lib/` (the generator reads every `lib/**.dart`; `bin/` and
  `test/` are not scanned) and have an unnamed constructor without required parameters — the build fails
  with file, line and class otherwise.
- Column defaults must be constant expressions; a non-constant one gives a build warning and no column
  default. Private classes and fields are not registered.
- In templates `{{ obj.field }}` works on `@Page` / `@Entity` objects (generated getters) and on Maps; on any
  other object it renders empty.
- Minimum Dart SDK 3.11 (the generator's `analyzer` / `source_gen`).

### Upgrading from 0.2.x

1. Add `build_runner` to `dev_dependencies` — nothing else; the generator is part of `ignis`.
2. Run `dart run build_runner build` (or keep `dart run build_runner watch` running) and commit the generated
   `lib/ignis_registry.g.dart`.
3. `import 'package:<your_app>/ignis_registry.g.dart';` and pass `registry: ignisRegistry` to `Ignis.start`.

For a compiled binary also set `IGNIS_PACKAGE_ROOT` to a copy of the ignis package directory (`templates/`,
`i18n/`, `web/`) — a binary has no package config.

### Added

- Registry builder `ignis|registry` (`package:ignis/builder.dart`, `build.yaml` in the package root): an
  aggregating builder, `auto_apply: dependents`, `build_to: source` — writes `lib/ignis_registry.g.dart` with
  `ignisRegistry` (entities, fields with getter/setter closures and const defaults, pages, `@Action` methods,
  synced fields, per-class template getters, and a source fingerprint). Deterministic output; no `build.yaml`
  or stub file in the app. The core's own registry ships generated in the `ignis` package (a `targets` entry
  in `build.yaml`). `analyzer`, `build` and `source_gen` are dependencies of `ignis`, imported only by the
  builder — not by `package:ignis/ignis.dart`, so not in the binary.
- The separate `ignis_builder` package (0.3.0 development builds only) was merged into ignis — drop it from
  `dev_dependencies`.
- `Ignis.start(registry:)` and `Ignis.resolveRegistry`; metadata types `IgnisRegistry`, `EntityMeta`,
  `FieldMeta`, `PageMeta`, `SyncedMeta`, `Fingerprint`.
- Stale-registry warning: the registry carries a `Fingerprint` (sha256 of the sorted `lib/**.dart` sources).
  Under `dart run`, when the sources are on disk, Ignis recomputes it and on a mismatch prints ONE warning
  (`dart run build_runner build` / `watch`) before running on the registry as generated. A binary has no
  sources and skips the check.
- `IGNIS_PACKAGE_ROOT` (AOT), `tool/aot_smoke.sh` (compiled binary vs `dart run`: health, sign-in, panel
  pages, CRUD round-trip, identical HTML).

### Removed

- `dart:mirrors` entirely: the runtime scan (`lib/engine/mirrors_scan.dart`), the mirrors attribute reader
  (`lib/engine/attribute_mirrors.dart`), their stubs, the JIT fallback and the `IGNIS_LEGACY_MIRRORS` switch.

### Changed

- Engine, ORM and schema read metadata through the registry closures only.
- The dashboard passes permission packages to its template as Maps.
- No change to SQL, multi-tenancy, RLS, authentication, sessions, templates or i18n; annotation signatures
  (`@Entity`, `@Cached`, `@Page`, `@Action`, …) are unchanged.

## 0.2.2 — 2026-11-19

### Changed

- `dart:mirrors` imports carry a targeted `// ignore: deprecated_member_use`: since Dart 3.14 the library is
  deprecated (dart-lang/sdk#44489), which failed `dart analyze --fatal-infos`. No global suppression.
- README: Ignis stays on `dart:mirrors` (Dart VM / JIT); if the library is removed, Ignis will switch to explicit
  registration of pages and entities (no code generation).
- No behaviour change.

## 0.2.1 — 2026-11-19

Hardening follow-up to 0.2.0 (HARD-L.13). Details in `SECURITY.md`.

### Upgrade notes

- **Customers sign in again.** Customer sessions stored by 0.2.0 carry no epoch and are rejected. Panel 2FA
  half-sessions (password entered, code not yet) written by 0.2.0 are still accepted, with the current epoch.
- **Rolling restart 0.2.0 → 0.2.1.** In a mixed window customer sessions created on one node version are
  rejected by the other (0.2.0 wants no epoch, 0.2.1 requires it), so without sticky sessions customers are
  signed out repeatedly while the window lasts; a 2FA half-session started on a 0.2.1 node fails its code step
  on a 0.2.0 node. A 0.2.0 node does not bump the epoch on a customer password change. Switch all nodes at once,
  or accept customers being signed out during the window; the epoch protection holds only after the full
  rollout.
- **No schema migration.** `users.session_epoch` exists since 0.2.0 (`Schema.sync` already created it); it now
  also guards customer sessions. Nodes on `IGNIS_SCHEMA=validate` start without a migration step.
- **New `503`:** `api: true` bodies above the node budget `IGNIS_API_BODY_BUDGET_MB` (64 MB) get `503` with
  `Retry-After`.
- **New `StateError`:** at start-up for `@Page(api: true)` / `@Page(cors: true)` on an `AdminPage` /
  `CustomerPage` subclass, and with `IGNIS_REQUIRE_RUNTIME_ROLE=1` when the role owns engine tables; at run
  time for a request query issued concurrently with an elevated block (`Db.asSystem` / `Db.asPlatform`) from
  outside it — `await` the block first.

### Security

- Customer sessions carry `users.session_epoch`, read together with the password hash at sign-in, and
  `CustomerAccounts.session()` compares it with the database. A customer password change (admin or reset link)
  bumps the epoch in the same statement and cleans Redis up after the transaction ends, so a session
  created with the old password in parallel, or one whose Redis key survived, is rejected. Customer sessions
  stored before this change have no epoch and are rejected — customers sign in again.
- The `striptags` template filter no longer unescapes its result: Jinja's version turned an escaped
  `<script>` from the model back into raw markup. Entities stay escaped; trusted `Html` still loses its tags
  (HTML comments too, also multi-line ones), and a `<` `>` `"` `'` left over is escaped, so the result is safe
  in an attribute value.
- A request query that runs while an elevated block (`Db.asSystem` / `Db.asPlatform`) of the same transaction
  holds its context, from outside that block (`Future.wait`, an un-awaited future), throws `StateError`
  instead of running with the elevated context and seeing every tenant.
- A customer password-reset token is consumed atomically (GET+DEL in one Redis script): of parallel resets with
  one link exactly one sets the password. A password rejected by the length rule does not use the link up; a
  database error after the consumption leaves it used.
- A panel sign-in stores the `session_epoch` read in the same query as the password hash
  (`Db.checkLoginWithEpoch`), and the 2FA half-session keeps the epoch of its password step: "sign out
  everywhere" or a password change committed while bcrypt runs, or while the code is being typed, leaves the new
  session with the old epoch, which the panel rejects. `Sessions.create` / `Sessions.halfSession` take an
  optional `epoch`. The code step compares the half-session's epoch with the database before creating the
  session, so a stale one gets "sign-in expired" instead of a cookie the panel rejects.

### Breaking

- `@Page(api: true)` or `@Page(cors: true)` on an `AdminPage` / `CustomerPage` subclass stops the node at
  start-up (`StateError` listing the routes): such routes skip CSRF while the session cookie authenticates them.
  Extend `PageEngine` and authenticate by a header token, or drop `api`/`cors` and keep CSRF.

### Added

- `IGNIS_API_BODY_BUDGET_MB` (64 MB by default): bodies of `api: true` routes share one node budget, counted
  as they are read on the wire and again as gzip inflates them, released when the request ends (also on a
  dropped connection or when the request deadline ends a hanging body). Over the budget the route answers `503`
  with `Retry-After`. A value other than an integer ≥ 1 stops the node at start-up.
- `IGNIS_REQUIRE_RUNTIME_ROLE=1` (opt-in): a node whose database role owns any engine table refuses to start
  instead of only warning — checked before the schema sync, so a refused node runs no DDL; any value other than
  empty or `1` also refuses to start. `tool/runtime_role.sql` holds the owner + runtime role recipe from `SECURITY.md`.
- CI `scan` job: `gitleaks` on the pushed / PR commits and `osv-scanner` on `pubspec.lock` (actions pinned by
  SHA); exception policy in `SECURITY.md`, "CI scans". gitleaks false positives are allowed by path in
  `.gitleaks.toml` (test fixtures), not by SHA-bound fingerprints.

### Documentation

- `SECURITY.md`: a "Supported versions" table (latest 0.2.x only); "Notes for app authors" on template output
  limits (`~`, `replace`, functions in the model) and on `Orm.readAll` / `CustomerAccounts.list` without
  `LIMIT`; the backend TLS profile added to the open owner decisions.

### Fixed

- `Redis.delMany` sends one `DEL` per key: a multi-key `DEL` across hash slots failed with `CROSSSLOT` on
  Redis Cluster, and the session / permission cache cleanup after a password change quietly did nothing.
- A customer password reset checks the password fingerprint on the token value its script consumed, not on an
  earlier read: a password change committed between the two now ends the link as well.
- The elevated-block guard checks the query in the same synchronous step that sends it (after the `await` that
  opens the request transaction, and again after `runTx`'s `SAVEPOINT`), and the block counts as raised before
  its `set_config` is sent: a query issued just before the block, while the transaction was still opening, could
  pass the check and then run with the elevated context. A refused un-awaited query ends its request with `500`
  (the `Engine.guarded` zone), not the process.

## 0.2.0 — 2026-11-19

Hardening release after an external review and its follow-up. Details in `SECURITY.md`.

### Security

- Elevated blocks (`Db.asSystem` / `Db.asPlatform`) inside a request restore the request's own context
  instead of a value read back from the database. The zone carries the block itself (with an `active` flag),
  so a Future that outlives its block no longer runs on the parent's elevated path; parallel blocks of one
  request — top-level or nested — are serialized, each restoring its parent's (or the request's) context.
  A block waiting over 30 s for its turn (e.g. a nested block awaited by its parent's sibling) gets a
  `StateError` instead of hanging. Tests cover overlapping, un-awaited and outliving blocks.
- `@Cached` mirror is invalidate-on-write and read-through: writes only delete the Redis key (right away and
  again after the transaction ends, commit or rollback), a session with uncommitted writes reads past the
  mirror and never fills it, and a reader fills it under a `SET NX` lease, so an older value read in
  parallel with a write is not stored. Mirrored `DateTime` values are UTC; an unparsable entry is a miss.
  `@Cached` is refused on every table under row-level security.
- Template rendering escapes a `MapEntry` in the model (`map.entries.toList()`) and every interpolated value
  that is not a string, number, bool or `Html` (objects with their own `toString()`, exceptions,
  records), also inside printed collections and in the `string` / `join` filters. Macros and `Html` are
  unchanged; the `~` operator is not covered (`SECURITY.md`).
- Start-up warning when a backend host (PostgreSQL, Redis, S3) is outside loopback while its TLS is off, and
  for a remote PostgreSQL with `IGNIS_DB_SSL=require` (certificate not verified).
- `IGNIS_TRUSTED_PROXIES` entries must be IPs or CIDRs: a host name, garbage or a `/0` prefix stops the node;
  `none` is accepted in any case.
- Start-up warning when the database role owns the engine tables while `IGNIS_SCHEMA` is not `update`;
  `SECURITY.md` has ready SQL for an owner (migrations) + runtime role (DML grants, `IGNIS_SCHEMA=validate`).

### Breaking

- `IGNIS_TRUSTED_PROXIES` is required: unset or empty, the node refuses to start with a message saying what
  to set. Behind a reverse proxy set the proxy's IPs/CIDRs; with clients connecting directly set
  `IGNIS_TRUSTED_PROXIES=none` (the previous default behaviour).

### Changed

- `Db.release()` / `Db.commit()` inside an elevated block throw `StateError`, and so does an elevated block
  that waits too long for its turn; an error in the block body is no longer masked by the context reset.
- `@Cached` on an entity whose table is under row-level security stops the node (`StateError`).
- `@Cached` writes invalidate the mirror instead of writing it; the next read refills it.
- `{{ x }}` with `x == null` prints an empty string (it used to print `null`).
- The default platform tenant is named `Platform`; the login page title has its own i18n key
  (`ignis.login.title`) instead of the submit button label.
- `IGNIS_MAX_INFLIGHT` other than an integer ≥ 1 stops the node (it used to fall back to 512 silently).
- `Schema.sync` and `Seed.seed` take the start-up lock with `pg_try_advisory_lock` in a loop: a wait is
  logged ("waiting for start-up lock") and gives up after 5 minutes; `Ignis.start` holds one lock around both.
- `pubspec.yaml` description is in English.

### Added

- Key rotation: `IGNIS_KEY_PREVIOUS` (decryption tries the current key, then the previous one) and
  `bin/rekey.dart`, which re-encrypts settings secrets and TOTP seeds under the current key — idempotent,
  reports the number of records, exits with 1 when a value is readable with neither key. The ciphertext
  format is unchanged. A malformed `IGNIS_KEY_PREVIOUS` stops the node.
- Backpressure: `IGNIS_MAX_INFLIGHT` (512 by default) — requests above it get `503` with `Retry-After`
  before routing (logged like other requests, at most one line a second); a request that cannot get a pool
  connection in time also gets `503` instead of `500`. This is a coarse limit, not a per-client quota.
- `bin/rekey.dart` counts only rows it actually updated (a value changed meanwhile is reported, not counted)
  and writes an audit log entry for each run.
- CI: GitHub Actions running `dart analyze`, the tests without a database and `tool/pg_test.sh`, each test
  file under a 300 s timeout; actions pinned to commit SHAs; Dependabot for `pub` and `github-actions`.
- Destructive PostgreSQL tests run only with `IGNIS_PG_TEST=1` (set by `tool/pg_test.sh`) against a database
  whose name contains `test`; otherwise they skip with a message, so a shared database is never touched.

### Fixed

- Nodes starting at the same time on a fresh database no longer race on `CREATE TABLE` / `ADD COLUMN`
  and the initial admin account: `Schema.sync` and `Seed.seed` run under one start-up advisory lock; an
  error in them is no longer masked by a failed unlock.
- `DateTime` fields read from the `@Cached` mirror come back as `DateTime`, not strings.
- Runtime messages and comments in `lib/` are in English; the empty partial-index hook in `schema.dart` is
  gone.
- Documentation: `SECURITY.md` covers PostgreSQL ≤ 14 (`REVOKE CREATE ON SCHEMA public`), the rolling-restart
  window of key rotation and the `~` template operator; it matches the code on the `users` policy, the README says which tests skip
  themselves without a database or Redis, the `@SessionSynced` Redis key is described correctly.

## 0.1.1 — 2026-11-18

### Added

- Configurable Content-Security-Policy: `Ignis.start(extraCsp: {...})` adds sources per directive to the
  base policy (e.g. an image host, `font-src`, `'wasm-unsafe-eval'` in `script-src`, `worker-src blob:`).
  Unknown directives, malformed sources and `'unsafe-inline'`/`'unsafe-eval'` in script directives abort
  start-up. Without it the policy is unchanged.
- The page header, error pages, static `.html` files and the `<meta>` in the package layouts all use the
  same computed policy (`Engine.csp`).

## 0.1.0 — 2026-11-18

First public release, after the security and performance review. Details in `SECURITY.md`.

### Security

- Tenant isolation: row-level security is required at startup, policies are checked by fingerprint and
  the read policy on `users` no longer exposes platform accounts to tenant contexts.
- The per-request transaction is lazy and system/platform context is transaction-local (safe behind a
  transaction-mode connection pooler).
- Sessions are revocable without Redis (per-account session epoch); cache invalidation and session
  teardown run after the request transaction ends.
- Login: rate limits per account+IP and per IP (IPv6 keyed by /64), soft per-account delay, constant
  bcrypt cost for unknown accounts, unknown logins never written to the audit log.
- Second factor: enabling or disabling it on your own account requires the password, attempt counter is
  fail-closed, replay protection is atomic, the pending secret is encrypted in Redis.
- CSRF is enforced for every non-API method other than GET/HEAD/OPTIONS, decided per route.
- Uploads: rejected before the body is read (size, CSRF cookie, session), bounded memory budget, storage
  quota re-checked under a lock, safe object-key extensions.
- Response hardening: CSP header on every HTML response, COOP, Permissions-Policy; redirects never carry
  a foreign host; panel scripts no longer assign `innerHTML`.
- Signed values are bound to a purpose with a derived HMAC key; settings fields are validated on save.

### Performance

- In-memory domain map, permission packages grouped once, keyset pagination for the audit log and
  paginated file lists.
- Static files: cached gzip, ETag and 304 for all assets; fewer per-request recomputations on the hot path.
- Uploads do not hold a database connection while transferring to object storage.

### Notes for apps

- Cookies use the `__Host-` prefix (`__Host-ignis_session`, `__Host-ignis_csrf`, `__Host-ignis_customer`),
  so HTTPS is required outside `localhost`.
- Passwords must be at least 10 characters.
- The node refuses to start when the database role is a superuser or has `BYPASSRLS`.
- A trivial `IGNIS_KEY` (one repeated character) is rejected at startup.
- CSRF tokens are now required on PUT/PATCH/DELETE form routes, not only POST.
- `Storage.files` returns at most 50 entries per call (`limit`/`from` for paging).
- `Signature.textValue(target, text)` takes a purpose label.
- Whole-request deadline `IGNIS_TIMEOUT_S` defaults to 120 s; routes without a body limit get a shorter one.
- The node binds to `127.0.0.1` by default (`IGNIS_BIND` to change).
- A database created by a pre-release build is upgraded in place on start-up (`engine/migration.dart`,
  one transaction, idempotent).
