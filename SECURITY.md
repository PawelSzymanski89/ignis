# Ignis security

This document describes the **actual state** of Ignis 0.2.1, not intentions. Every point maps to a
file you can check. Open problems are listed under "Known gaps", not left out.

> The first public release (0.1.0) included the pre-release audit fixes for areas A (tenant isolation / auth),
> B (network edge / headers) and C/D (panel, audit log, documentation). 0.2.0 closes the findings of the
> follow-up hardening review (elevated-block context, backpressure, render escaping, key rotation, runtime role);
> 0.2.1 closes the next round (session epochs, cookie-authenticated API routes, `striptags`, API body budget,
> reset-token race, CI scans).

## Supported versions

| Version | Security fixes |
|---|---|
| latest 0.2.x | yes |
| older | no — upgrade to the latest 0.2.x |

## Reporting a vulnerability

Report privately, never in a public issue: open a GitHub Security Advisory at
<https://github.com/PawelSzymanski89/ignis/security/advisories/new>. Include what, where (file and
line, or URL), how to reproduce, and the impact. Do not test against anyone's production — there is a
local environment and a test account.

## Threat model

Two things must not happen, ordered by impact:

1. **Data leak between tenants.** Service A must never see service B's data. This is threat number
   one, because one install serves many services.
2. **Back-office account takeover.** Whoever reaches the panel has access to everything the account's
   permissions allow.

## Tenant isolation

Four independent layers, none sufficient on its own:

| Layer | Where | What it does |
|---|---|---|
| Row-Level Security | `engine/schema.dart`, `engine/db.dart` | a policy on every table with a `service` column; a query without a filter returns only its own rows, a write into another service is rejected |
| context from the domain | `engine/tenant.dart` | the service is decided by the `Host` header, once, before the page lifecycle. An unknown domain is 404 — never a "default service" |
| data-layer filter | app code, `engine/permissions.dart`, `audit_log.dart`, … | **every** query carries `service=@s`; functions take the service as a required parameter, so the compiler flags omissions |
| `__Host-` cookies | `engine/session.dart`, `engine/page_engine.dart` | session cookies (`__Host-ignis_session`, `__Host-ignis_customer`) have no `Domain`, `Path=/` and `Secure`, so a cookie from `admin.example.com` does not work on `admin.example.org` and a sibling subdomain cannot plant one |

Entering the panel requires crossing **four barriers** (`engine/admin_page.dart`): the `admin.<domain>`
address, the `staff` realm, the account belonging to *this* service, and the permission from `@Page`.

### RLS is fail-closed

- `Db.inContext` runs the request on a single **transaction** and sets `ignis.service` **locally**
  (`set_config(..., true)`), so it holds even behind a transaction-pooling PgBouncer. The policies
  (`Schema._rls`) read that value.
- **PgBouncer**: the request path (`Db.inContext`, `Db.asSystem`) is safe in `pool_mode = transaction` —
  every context lives inside one transaction and dies with COMMIT/ROLLBACK. Schema sync, seed and the
  `bin/` tools use the session-level `Db.asSystemSession` and need a **direct** Postgres connection
  (or a `session`-mode pool): run them with `IGNIS_DB_HOST`/`IGNIS_DB_PORT` pointing at Postgres itself.
- **What RLS does and does not cover**: it catches a *forgotten* `service` filter in engine or app code. It
  is **not** a defence against SQL injection — the application role can call `set_config('ignis.service',
  '*', true)` itself, so injected SQL can widen its own context. Parameterised queries (`Sql.named`) are
  that defence.
- **The database role must not be a superuser or have `BYPASSRLS`** — `FORCE` does not bind such roles;
  `Schema.checkRls` refuses to start with one.
- **No context = zero rows.** A pooled connection without a context sees nothing on RLS tables —
  the opposite of a default-open setup. Full access (`'*'`) is reached only explicitly: at runtime
  through `Db.asSystem` (domain→service lookup, log-retention sweep) — one transaction with a local
  `set_config`, like a request — and through the session-level `Db.asSystemSession`, used only by
  the schema builder, the seed and the `bin/` tools. Context `'0'` is the platform panel.
- Covered are **all tables with a `service` column**, with `FORCE ROW LEVEL SECURITY`, because the app
  role owns the tables and would otherwise bypass its own policies (see "Runtime database role" below
  for running nodes on a role that owns nothing).
- The write policy is **strict** (`service = context`). Read-only exceptions are explicit: `audit_log`
  also shows rows with `target = <service>` (platform actions about this service). This read exception
  does not grant the right to write those rows. `users` has no exception: a service does not see
  platform accounts (`service = 0`).
- Setup failures are not swallowed: `Schema.checkRls` verifies `ENABLE`+`FORCE` and the full policy
  set (with no foreign policies) in every `IGNIS_SCHEMA` mode; a mismatch aborts start-up.

### Runtime database role

The role that owns the tables can `ALTER`/`DROP` their policies. Split it: the **owner** only migrates
(one deploy step or one node with `IGNIS_SCHEMA=update`), the serving nodes run on a **runtime role** with
DML grants and `IGNIS_SCHEMA=validate`. Run as a superuser, once (names are examples; the same script is in
`tool/runtime_role.sql`):

```sql
CREATE ROLE ignis_owner LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD '…';
CREATE ROLE ignis_rt    LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD '…';
CREATE DATABASE ignis OWNER ignis_owner;
\c ignis
-- (PostgreSQL 15+: the public schema is owned by pg_database_owner, i.e. ignis_owner, and PUBLIC has no
-- CREATE on it. PostgreSQL ≤ 14: public is owned by the bootstrap superuser and every role may create
-- objects there — the REVOKE below is then required, and the owner needs GRANT CREATE ON SCHEMA public
-- TO ignis_owner, or ALTER SCHEMA public OWNER TO ignis_owner.)
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO ignis_rt;
-- tables created by the owner from now on (every migration):
ALTER DEFAULT PRIVILEGES FOR ROLE ignis_owner IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ignis_rt;
ALTER DEFAULT PRIVILEGES FOR ROLE ignis_owner IN SCHEMA public
  GRANT USAGE ON SEQUENCES TO ignis_rt;
-- tables that already exist (an install that ran as one role so far; also fine to repeat):
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ignis_rt;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO ignis_rt;
```

- Migrate: `IGNIS_DB_USER=ignis_owner IGNIS_SCHEMA=update` (an existing install: transfer ownership with
  `ALTER TABLE … OWNER TO ignis_owner` first, or keep the current role as the owner).
- Serve: `IGNIS_DB_USER=ignis_rt IGNIS_SCHEMA=validate`. `Schema.checkRls` and the seed work on this role;
  policy changes and DDL fail with `42501 must be owner`. `IGNIS_SCHEMA=update` on it fails the same way.
- With `IGNIS_REQUIRE_RUNTIME_ROLE=1` a node whose role owns any engine table refuses to start (`StateError`),
  in every `IGNIS_SCHEMA` mode and before the schema sync (no DDL first) — set it on serving nodes, not on the
  migrating one. A value other than empty or `1` also refuses to start.
- A node whose role owns the engine tables while `IGNIS_SCHEMA` is not `update` logs a warning at start-up.
  In the default single-role setup with `IGNIS_SCHEMA=update` (the default) there is no warning — that role
  owns the tables by design. A superuser or `BYPASSRLS` role is not warned about but refused (above).
- Limit: the runtime role can still widen its own context with `set_config('ignis.service', '*', true)`
  (see above) — the split stops lasting policy changes, not context widening by injected SQL.

## Authentication and sessions

- **Back-office**: password + bcrypt (cost 12; lower-cost hashes are rehashed on a successful login),
  verified on a separate isolate (`engine/db.dart`). Passwords must be 10 characters up to 72 bytes
  (`Db.passwordError`) — panel, front accounts, `bin/account.dart` and `IGNIS_ADMIN_PASS`.
  Login is for `realm='staff'` only — customer accounts have an empty hash and cannot use this path.
- **Front accounts** (`realm='customer'`, `engine/customer_accounts.dart`): password + bcrypt, password
  reset via a single-use token (1 h, invalidated by a password change, consumed atomically), a separate session cookie.
- **Sessions** live in the shared Redis, keyed by the SHA-256 of the token (a Redis dump does not
  expose live tokens); cookies are `__Host-` prefixed `HttpOnly` + `Secure` + `SameSite=Lax`
  (`__Host-ignis_session` for the panel, `__Host-ignis_customer` for customers, `__Host-ignis_csrf`). A
  password change or account deletion kills all sessions — after the request's transaction ends
  (`Db.afterTransaction`), as does dropping the permission cache, so a parallel request cannot re-cache the old
  permissions or log in with the old password between the kill and COMMIT. Panel and customer sessions both carry
  `users.session_epoch`, compared with the database on every request; a password change bumps it, so a session that
  outlives the Redis cleanup is still rejected. The epoch of a new session is the one read with the password hash
  (for 2FA: at the password step), so a change committed during bcrypt or while the code is typed also counts. Session, 2FA, reset and client tokens are
  matched against `^[0-9a-f]{48}$` before Redis.
- **Rate limits**: login 30 attempts / 5 min per IP, then 5 / 5 min per login+IP pair (panel and
  front), so a foreign address cannot lock someone else's account. The client IP comes from
  `X-Forwarded-For` only behind `IGNIS_TRUSTED_PROXIES`. The second factor is limited **per account**
  (10 wrong codes → 1 h lock), above the per-token counter, so a fresh half-token does not buy new
  tries; an accepted TOTP code cannot be replayed. Limits **fail closed** when Redis is down — there
  is no session without Redis anyway, and a disabled limiter would be a password oracle.

## Second factor

- **TOTP (RFC 6238)**, own implementation with no dependency, checked against the RFC Appendix B
  vectors (`engine/totp.dart`, `test/totp_test.dart`). The secret lives in `users.totp` encrypted with
  `IGNIS_KEY`, so a database copy without the key cannot generate codes.
- A password only reaches a half-authenticated state (`2fa:` in Redis, 5 minutes); the session is
  created after a correct code. Enrolment writes the secret **only after** it is confirmed with a code,
  so a transcription slip cannot lock the account. A lost phone is cleared by an administrator from the
  permissions panel, with a audit log entry.
- **If the TOTP ciphertext cannot be decrypted, login is denied** rather than silently skipping the
  factor.

## Input

- **SQL**: parameterised queries only (`Sql.named`). Interpolated parts are literals from code (column
  names, constant conditions), never user data.
- **XSS**: Jinja 0.6.7 has **no autoescape**, so escaping is done by `Renderer` (`engine/render.dart`)
  — every String in the model, in nested maps and lists, and object fields read via mirrors; at output, any
  other value (objects with their own `toString()`, exceptions, records), also inside a printed collection and
  in the `string` / `join` filters. `striptags` is Ignis' own: Jinja's version unescapes its result, which
  turned an escaped `<script>` from the model back into markup; ours escapes `<` `>` `"` `'` left in its result. Trusted HTML passes only as `Html(...)`.
  Known limits: the `~` operator concatenates through `toString()` before escaping, so `{{ obj ~ 'x' }}` prints
  the object's `toString()` raw — pass strings (escaped by the model) to `~`, or format the value in Dart; and
  `replace` works on the escaped text, so `{{ x|replace('&lt;', '<') }}` rebuilds markup — never replace
  entities with characters. **User data never goes into
  JavaScript**: confirmations use `data-*`, and the brand reaches JS through `document.body.dataset.brand`,
  because an HTML attribute is decoded before the JS engine sees it.
- **CSP**: both layouts ship a default `Content-Security-Policy` (`script-src 'self'`, `object-src
  'none'`, `base-uri`/`form-action 'self'`). All scripts are files under `/assets/`; there are no inline
  `<script>`, `on*=` handlers or `javascript:` URLs. Uploaded objects are served with `nosniff` and
  `Content-Security-Policy: sandbox`, and non-image types with `Content-Disposition: attachment`; `/files` serves only under
  the owning service's domain.
- **CSRF**: double-submit with the `__Host-ignis_csrf` cookie; a POST without a matching field is 403.
  `@Action` methods run **on POST only**, so a plain link cannot trigger an action.
- **Body limits**: multipart is accepted **only** on routes that declare `maxBody` (others, including
  `/admin/login`, get 413 before the body is read); `/admin/files` allows 16 MB, settings routes
  256 KB. The urlencoded limit (256 KB) is counted incrementally.
- **Client address** (`__ip`) is set **after** the body is parsed, and `X-Forwarded-For` is trusted
  only from `IGNIS_TRUSTED_PROXIES`.

## Secrets

- Service secrets (settings fields of type `password`/`file`) are stored in `settings` **encrypted with
  AES-GCM** under `IGNIS_KEY` (`engine/crypto.dart`). **Without a valid key the node does not start**
  — otherwise secrets would hit the database in plaintext.
- **Key rotation** (ciphertexts carry no key id, so it is two-key, not a keyring):
  1. on every node set the new key in `IGNIS_KEY` and the old one in `IGNIS_KEY_PREVIOUS`, restart —
     decryption tries the current key first, then the previous one; new writes use the current key;
  2. run `dart run bin/rekey.dart` once (same environment): it re-encrypts settings secrets and TOTP seeds
     under the current key, is idempotent and prints how many records it changed; exit code 1 means some
     value is readable with neither key — keep `IGNIS_KEY_PREVIOUS` until that is explained; a value changed
     while it ran is reported as "changed meanwhile" (run it again); every run leaves an audit log entry;
  3. remove `IGNIS_KEY_PREVIOUS` and restart.
  During a rolling restart in step 1, nodes still on the old key alone cannot read secrets that already-
  restarted nodes wrote under the new key (they read as empty, and TOTP sign-in for such an account fails
  closed): keep the window short, avoid editing secrets or enabling TOTP until every node runs with both
  keys, and run step 2 only after that.
  Signatures (`engine/signature.dart`) use only the current key: signed links issued before the rotation
  stop verifying. A malformed `IGNIS_KEY_PREVIOUS` stops the node.
- Secrets **do not return to the browser**: the form only knows "set / unset", and an empty field on
  save means "leave unchanged".
- Infrastructure credentials (database, Redis, S3) come from environment variables, not the repo.
- **Signed links and messages** use an HMAC under the node key (`engine/signature.dart`, constant-time
  compares): identifiers in a URL can be guessable, a signature is not.

## Network edge

The node sets secure defaults on every response (`engine/engine.dart`): `X-Content-Type-Options:
nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, `X-Frame-Options: SAMEORIGIN`, panel HTML
`Cache-Control: no-store` and `Vary: HX-Request`. HSTS is opt-in (`IGNIS_HSTS=1`) so that enabling it
behind a TLS-terminating proxy does not pin a plaintext deployment for a year. HTML pages are **not
gzip-compressed** by the node (CSRF token next to reflected input = BREACH); compressing them is a
proxy decision. A whole-request deadline applies (`IGNIS_TIMEOUT_S`, default 120 s).

Still delegated to the deployment: TLS termination and a trusted reverse proxy. Postgres, Redis and S3
must not be exposed outside the application instances. When backend traffic leaves the private network,
enable TLS with certificate verification: `IGNIS_DB_SSL=verify-full` (`require` encrypts without
verifying), `IGNIS_S3_SSL=1`, `IGNIS_REDIS_TLS=1` (system CAs). An unknown `IGNIS_DB_SSL` value aborts
start-up. The node warns at start-up for every backend host outside loopback with TLS off, and for a remote
PostgreSQL with `IGNIS_DB_SSL=require` (no certificate check). Entries of `IGNIS_TRUSTED_PROXIES` must be IPs or
CIDRs; a host name, a typo or a `/0` prefix stops the node.

### Sample reverse-proxy configuration

```nginx
server {
    listen 443 ssl;
    server_name admin.example.com;

    # TLS, HSTS at the edge (the node sets HSTS only with IGNIS_HSTS=1)
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # the node accepts uploads up to 16 MB and ends a request after IGNIS_TIMEOUT_S (120 s)
    client_max_body_size  16m;
    client_body_timeout   30s;
    client_header_timeout 15s;
    send_timeout          60s;
    proxy_read_timeout    125s;

    location / {
        proxy_pass http://10.0.0.10:8080;
        proxy_set_header Host              $host;           # the node derives the tenant from Host
        proxy_set_header X-Forwarded-For   $remote_addr;    # REQUIRED — see below
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Set `IGNIS_TRUSTED_PROXIES` to the proxy address so the node accepts `X-Forwarded-For` from it and
nowhere else. Otherwise every client looks like the proxy: the login limits then lock out everyone at
once and the audit log records only the proxy IP. **The node refuses to start with the variable unset or
empty**; set `IGNIS_TRUSTED_PROXIES=none` when clients connect directly (the node then still warns on the
first `X-Forwarded-For` from a private address).

The proxy **must set `X-Forwarded-For`** on every forwarded request. `/health` answers only the loopback
and `IGNIS_TRUSTED_PROXIES` *without* that header (the proxy's own probe); a proxy that forwards client
requests without it makes the health check — with node and backend state — public.

## Accountability

- **Every panel action leaves an entry** (`engine/audit_log.dart`), written centrally in `engine.dart`,
  with the outcome `ok` / `denied` / `error`; login and 2FA events (success, denial, lock-out,
  wrong-service account) are logged too. A new page cannot fall out of the audit by oversight.
- **The audit log does not copy secrets**: fields whose name looks like a secret (`password`, `pass`, `token`,
  `secret`, `key`, `cert`, `pin`, plus common Polish names such as `haslo`/`klucz`) and password-change fields
  (`old`, `new`, `repeat`) are stored as `(hidden)`, guarded by
  `test/audit_log_test.dart`.
- Platform actions about a given service are stored as `service = 0, target = <service>` and show up in that
  service's audit log. Retention is 400 days, swept once a day under a Redis lock.

## Panel passwords and the emergency console

- **A password set by someone else must be changed** on first login (`users.must_change_password`): the panel
  lets such an account reach only `/admin/account`. This covers the seed account, accounts created
  by the owner and admin resets.
- **Changing your own password requires the current one** and kills all of the account's sessions.
- `bin/account.dart` (console-only, needs `.env`) clears the second factor and sets a password when
  nobody can log in; `bin/purge.dart` removes a service with all of its data. Both read passwords
  from **stdin**, not argv, and leave a `console:<user>` audit log entry.

## Platform (owner) panel

- **The platform context is not a permission.** Data-changing actions still require `*.edit`, even when
  reachable only from the platform panel.
- **Value dictionaries live in code** — the same list renders the select and rejects an out-of-range
  POST value.
- **Login collisions are detected by the engine**, not just the form.

## Known gaps and debt

| What | Impact | Where |
|---|---|---|
| **coarse request-concurrency limit** | one isolate per node; above `IGNIS_MAX_INFLIGHT` (512) requests in flight, or when no pool connection frees up within 5 s, the node answers `503` with `Retry-After`; API bodies share `IGNIS_API_BODY_BUDGET_MB` (64 MB) and multipart uploads `IGNIS_UPLOAD_BUDGET_MB` (64 MB), other form bodies (256 KB each) only the request limit | `engine/engine.dart` (`Engine.guarded`), `engine/db.dart` |
| **pagination only where `Listing` is used** | pages without it load everything; `Orm.readAll` and `CustomerAccounts.list` have no `LIMIT` | panel, `engine/orm.dart`, `engine/customer_accounts.dart` |
| **backend TLS is off by default and not mutually authenticated** | relies on a private network unless `IGNIS_DB_SSL` / `IGNIS_S3_SSL` / `IGNIS_REDIS_TLS` are set; a non-loopback host without TLS is warned about at start-up | deployment |
| **one database role by default** | RLS holds via `FORCE`, but if nodes run on the table owner a compromised node could `ALTER`/`DROP` policies; splitting owner and runtime role is a deployment step ([Runtime database role](#runtime-database-role)); a warning is logged only when the owner role runs with `IGNIS_SCHEMA` other than `update` (the default single-role setup is silent); `IGNIS_REQUIRE_RUNTIME_ROLE=1` turns ownership into a start-up refusal (opt-in) | deployment, `engine/schema.dart` |

### Open decisions (owner)

| Decision | Why it is open |
|---|---|
| **tenant subdomains** | fronts and panels on system subdomains share an origin / are same-site with the platform panel — a Public Suffix List entry or a separate registrable domain |
| **staff login namespace** | logins are global (existence oracle, squatting); per-tenant namespacing as for customer accounts is the alternative |
| **breached-password check** | whether to check new panel passwords against a breached-password list (an offline list, or an opt-in online k-anonymity lookup) |
| **production TLS profile for backends** | whether a remote PostgreSQL / Redis / S3 host without TLS should stop the node (opt-in or by default) instead of the start-up warning |

## CI scans

- The `scan` job runs `gitleaks` on the pushed / pull-request commits and `osv-scanner` on `pubspec.lock`;
  a finding fails the job. Actions are pinned by commit SHA.
- Exceptions: a gitleaks false positive goes to the path allowlist in `.gitleaks.toml` (test fixtures under
  `test/`) or gets a `gitleaks:allow` comment on its line — not a `.gitleaksignore` fingerprint, which carries the
  commit SHA and stops matching after a squash or rebase. There are no accepted osv-scanner advisories; a finding
  is fixed by upgrading the dependency. Each exception names its owner, the reason and a review-by date; an
  expired one is removed or renewed with a new reason, not left in place.
- `pubspec.lock` is committed, so the job scans the resolved versions without running `dart pub get`.

## Third-party notes

- `pointycastle` (AES-GCM) is not constant-time. Dependencies use caret ranges; `pubspec.lock` is
  committed and should be tracked against advisories.

## What we do not simplify

In these places there is no "faster version": validation at the trust boundary, error handling that
protects data, the `service` filter in queries, escaping in the renderer, and server-side permission
checks (hiding a button is convenience, not a control).

## Notes for app authors

These are deliberate limits of the engine API, not bugs; code built on Ignis has to respect them.

- **Tenant scope of framework state.** `@Synced` fields live under one global Redis key
  (`synced:<Class>.<field>`) shared by every tenant — use them only for platform-wide state, never for
  per-tenant data. `@Cached` is refused on every entity whose table is under RLS (not only those with a
  `service` column), because the Redis mirror does not know the tenant. Writes only invalidate the mirror (right away
  and after COMMIT/ROLLBACK); it is filled by reads (read-through) outside a writing transaction, so uncommitted
  data never reaches Redis. `Orm.read`,
  `Orm.readAll` and `Orm.delete` filter by primary key only and rely on RLS; domain queries must still
  carry `AND service = @s` (QUALITY.md).
- **Elevated blocks share their request's transaction.** Inside a request, `Db.asSystem` and
  `Db.asPlatform` switch `ignis.service` on the request's single transaction for the duration of the
  body. A query of the same request that runs *concurrently* from outside the block
  (`Future.wait([Db.asSystem(a), b()])`, an un-awaited future) throws `StateError` instead of seeing every
  tenant. Always `await` an elevated block before issuing other queries.
  Elevated blocks of one request run one after another (an overlapping block waits), and after the last
  one the request's own context is restored — it is never read back from the database. `Db.release()` and
  `Db.commit()` inside an elevated block throw `StateError`: they would end the transaction the block runs in.
- **Password-reset mail must not be sent inline.** `CustomerAccounts.resetToken` returns `null` for unknown
  accounts. If the page then `await`s an SMTP send only when a token came back, response time reveals
  which e-mails have accounts. Send in the background (`unawaited(...)` or a queue) and answer immediately.
- **Keep `IGNIS_KEY` backed up.** Losing it makes every stored secret and TOTP seed unreadable; rotate
  it with `IGNIS_KEY_PREVIOUS` + `bin/rekey.dart` (see [Secrets](#secrets)), never by just replacing it.
  The node refuses a key made of one repeated character (e.g. 64 zeros).
- **CSRF covers every unsafe method.** Non-API routes require the `csrf` token for any method other than
  GET/HEAD/OPTIONS (PUT, PATCH and DELETE included), sent in an `x-www-form-urlencoded` body. Only routes
  declared `@Page(api: true)` skip it; an API path prefix alone selects the JSON error format, not the exemption.
  An API route therefore must not authenticate by cookie (`SameSite=Lax` does not stop a sibling subdomain, which
  is same-site): `api: true` or `cors: true` on an `AdminPage` / `CustomerPage` subclass stops the node at
  start-up. A plain `PageEngine` API route that reads a session cookie itself is not detected — authenticate
  API routes by a token in a header.
- **Template output.** Escaping covers data in the model, not code: a function put into the model and called
  in the template returns raw text, the `~` operator and `replace` work around escaping (see [Input](#input)).
  Format values in Dart and pass strings; trusted markup goes only through `Html(...)`.
- **Unbounded reads.** `Orm.readAll` and `CustomerAccounts.list` load every row the tenant sees, without
  `LIMIT` — use them only for small tables; lists that grow with users or traffic belong in `Listing` or a
  query with `LIMIT`.
- **`/health` relies on the proxy.** The health endpoint is limited to direct (loopback) clients. Behind a
  reverse proxy that does not set `X-Forwarded-For`, every request looks local, so the endpoint becomes public.
  The shipped nginx sample sets the header; custom proxies must do the same.
