# Changelog

## 0.2.0 — 2026-11-18

Hardening release after an external review. Details in `SECURITY.md`.

### Security

- Elevated blocks (`Db.asSystem` / `Db.asPlatform`) inside a request restore the request's own context
  instead of a value read back from the database, so overlapping blocks can no longer leave a request
  elevated; blocks of one request are serialized. `Db.release()` / `Db.commit()` inside such a block throw
  `StateError`, and an error in the block body is no longer masked by the context reset.
- `@Cached` mirror: written to Redis only after COMMIT and dropped after the transaction ends (no phantom
  rows after a rollback); `@Cached` is refused on every table under row-level security.
- Template rendering escapes a `MapEntry` in the model (`map.entries.toList()`) and every interpolated value
  that is not a string, number, bool or `Html` (objects with their own `toString()`, exceptions,
  records), also inside printed collections and in the `string` / `join` filters. Macros and `Html` are
  unchanged; the `~` operator is not covered (`SECURITY.md`).
- Start-up warning when a backend host (PostgreSQL, Redis, S3) is outside loopback while its TLS is off.
- Start-up warning when the database role owns the engine tables while `IGNIS_SCHEMA` is not `update`;
  `SECURITY.md` has ready SQL for an owner (migrations) + runtime role (DML grants, `IGNIS_SCHEMA=validate`).

### Breaking

- `IGNIS_TRUSTED_PROXIES` is required: unset or empty, the node refuses to start with a message saying what
  to set. Behind a reverse proxy set the proxy's IPs/CIDRs; with clients connecting directly set
  `IGNIS_TRUSTED_PROXIES=none` (the previous default behaviour).

### Changed

- `{{ x }}` with `x == null` prints an empty string (it used to print `null`).

### Added

- Key rotation: `IGNIS_KEY_PREVIOUS` (decryption tries the current key, then the previous one) and
  `bin/rekey.dart`, which re-encrypts settings secrets and TOTP seeds under the current key — idempotent,
  reports the number of records, exits with 1 when a value is readable with neither key. The ciphertext
  format is unchanged. A malformed `IGNIS_KEY_PREVIOUS` stops the node.
- Backpressure: `IGNIS_MAX_INFLIGHT` (512 by default) — requests above it get `503` with `Retry-After`
  before routing; a request that cannot get a pool connection in time also gets `503` instead of `500`.
- CI: GitHub Actions running `dart analyze`, the tests without a database and `tool/pg_test.sh`;
  Dependabot for `pub` and `github-actions`.

### Fixed

- Nodes starting at the same time on a fresh database no longer race on `CREATE TABLE` / `ADD COLUMN`
  and the initial admin account: `Schema.sync` and `Seed.seed` share one start-up advisory lock.
- `DateTime` fields read from the `@Cached` mirror come back as `DateTime`, not strings.
- Runtime messages and comments in `lib/` are in English (the default platform tenant name is now
  `Platform`, the login page title comes from i18n); the empty partial-index hook in `schema.dart` is gone.
- Documentation: `SECURITY.md` matches the code on the `users` policy, the README says which tests skip
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
