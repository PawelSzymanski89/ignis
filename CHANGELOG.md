# Changelog

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
