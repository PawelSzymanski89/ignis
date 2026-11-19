# Changelog

## Unreleased

### Security

- Customer sessions carry `users.session_epoch`, read together with the password hash at sign-in, and
  `CustomerAccounts.session()` compares it with the database. A customer password change (admin or reset link)
  bumps the epoch in the same statement and cleans Redis up after the transaction ends, so a session
  created with the old password in parallel, or one whose Redis key survived, is rejected. Customer sessions
  stored before this change have no epoch and are rejected — customers sign in again once.
- The `striptags` template filter no longer unescapes its result: Jinja's version turned an escaped
  `<script>` from the model back into raw markup. Entities stay escaped; trusted `Html` still loses its tags.
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
  optional `epoch`; a half-session from before this change is treated as expired.

### Breaking

- `@Page(api: true)` or `@Page(cors: true)` on an `AdminPage` / `CustomerPage` subclass stops the node at
  start-up (`StateError` listing the routes): such routes skip CSRF while the session cookie authenticates them.
  Extend `PageEngine` and authenticate by a header token, or drop `api`/`cors` and keep CSRF.

### Added

- `IGNIS_API_BODY_BUDGET_MB` (64 MB by default): bodies of `api: true` routes share one node budget, counted
  as they are read on the wire and again as gzip inflates them, released when the request ends (also on a
  dropped connection). Over the budget the route answers `503` with `Retry-After`.

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
