<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/banner.svg">
  <source media="(prefers-color-scheme: light)" srcset="assets/banner-light.svg">
  <img alt="Ignis — a bare multi-tenant web engine for Dart" src="assets/banner.svg" width="100%">
</picture>

<h3>Server-rendered, multi-tenant back-office apps in Dart — isolated by PostgreSQL row-level security, declared with annotations.</h3>

[![Release](https://img.shields.io/github/v/release/PawelSzymanski89/ignis?color=ff7a18&label=release)](https://github.com/PawelSzymanski89/ignis/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dart SDK](https://img.shields.io/badge/Dart%20SDK-%3E%3D3.11-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-13%2B-4169E1?logo=postgresql&logoColor=white)](https://www.postgresql.org)
[![Redis](https://img.shields.io/badge/Redis-required-DC382D?logo=redis&logoColor=white)](https://redis.io)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](#contributing)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-cygan-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/cygan)

<p>
  <a href="#quick-start"><b>Quick start</b></a> ·
  <a href="#features"><b>Features</b></a> ·
  <a href="SECURITY.md"><b>Docs</b></a> ·
  <a href="#security"><b>Security</b></a> ·
  <a href="CHANGELOG.md"><b>Changelog</b></a>
</p>

</div>

---

Ignis is a Dart package for **server-rendered back-office applications**: pages and entities declared with
annotations, Jinja templates, an `/admin` panel with accounts and permissions, and many services (tenants)
under their own domains in a single install. It ships no domain modules — everything beyond the core is
added by an **application** that depends on `ignis`. The same app runs under `dart run` and as **one
self-contained native binary** (`dart compile exe`).

## At a glance

One entity and one panel page — a table with an RLS policy, a route, a menu entry, a permission check and
a POST action. Drop it anywhere under `lib/` — the generator that ships in `ignis` picks it up on the next
build:

```dart
import 'package:ignis/ignis.dart';

@Entity('notes')
class Note {
  int? id;            // primary key — bigserial, assigned by the database
  int service = 0;    // a `service` column ⇒ an RLS policy is created for this table
  String text = '';
}

@Page('/admin/notes',
    template: 'notes.html',   // your templates/notes.html
    requires: 'notes.view',   // declared in Ignis.start(permissions: [...])
    label: 'Notes',           // menu entry, shown only to accounts with `requires`
    icon: 'fe fe-file-text',
    group: 'Content',
    order: 10)
class NotesPage extends AdminPage {
  // runs on POST with triggerAction=add (CSRF already checked by the engine)
  @Action('add')
  Future<bool> add() async {
    if (!can('notes.edit')) return missingPermission('notes.edit');
    await Orm.save(Note()
      ..service = context.service
      ..text = get('text') ?? '');
    return back('/admin/notes', message: 'Saved');
  }

  @override
  Future<void> insertData() async {
    await sharedData(); // menu, signed-in account, flash message
    put('notes', await Orm.pick<Note>(
        'SELECT * FROM notes WHERE service = @s ORDER BY id', {'s': context.service}));
  }
}
```

Every string in the model is HTML-escaped before it reaches the template; `Html(...)` marks trusted markup.

## Table of contents

- [Why Ignis](#why-ignis)
- [Features](#features)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Development loop](#development-loop)
- [Deployment and AOT](#deployment-and-aot)
- [Templates](#templates)
- [Why no `dart:mirrors`](#why-no-dartmirrors)
- [Caching](#-caching)
- [Architecture](#architecture)
- [Configuration](#configuration)
- [Content-Security-Policy](#content-security-policy)
- [Testing](#testing)
- [Status](#status)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [Security](#security)
- [License](#license)
- [Support](#support)

## Why Ignis

<table>
<tr>
<td width="50%" valign="top">

### 🏢 One install, many tenants

The tenant comes from the `Host` header, and PostgreSQL **Row-Level Security is fail-closed** underneath the
application filter: a forgotten `WHERE service = …` returns nothing instead of someone else's data. The node
refuses to start on a superuser or `BYPASSRLS` role.

</td>
<td width="50%" valign="top">

### 🧾 Boring server-side HTML

Pages render on the server and htmx swaps fragments. No SPA build, no client-side state, no inline
JavaScript — so the script policy can be strict: `script-src 'self'`, sent as a **`Content-Security-Policy`
header on every HTML response** and repeated as a `<meta>` in the package layouts.

</td>
</tr>
<tr>
<td width="50%" valign="top">

### 🏷️ Annotations, not glue

`@Page` and `@Entity` give you routes, menu entries, permissions, tables and RLS policies. Nothing is
registered by hand: the generator that ships in `ignis` finds every annotated class under `lib/` and writes a
plain Dart registry — so the same app runs under `dart run` and as one native binary.

</td>
<td width="50%" valign="top">

### 🔐 Secure by default

CSRF on every unsafe method, `__Host-` cookies, login rate limits, AES-GCM-encrypted secrets, an audit log
of every panel action, a request deadline and hardened response headers are on without opting in; a TOTP
second factor is built into the panel.

</td>
</tr>
</table>

## Features

| | Area | What you get |
|---|---|---|
| 🧭 | **Routing** | Page lifecycle `doBeforeProcess → isAbleToSee → processData → @Action (POST only) → insertData → render`; route parameters (`/v1/items/{id}`); per-route methods, body limits and CORS; CSRF, a request deadline and secure default headers |
| 🎨 | **Rendering** | Jinja templates with escaping by default (`Html(...)` for trusted markup), app templates override package ones, versioned static assets (`?v=`), gzip + ETag + 304 for `/assets/` |
| 🗄️ | **Data** | ORM with auto-schema (`update \| validate \| none`) and RLS policies for every table with a `service` column; settings registry with AES-GCM-encrypted secrets; CSV, paging, sorting and date-range components |
| 🔑 | **Auth** | Login with TOTP second factor (RFC 6238), forced password change and rate limits; accounts, permission packages, grants and denials with a panel to manage them; front-end customer accounts (password, reset token, separate session); JWT RS256 and HMAC-signed links |
| 🏢 | **Tenancy** | Tenant resolved from `Host` once per request; a per-request transaction with `ignis.service` set locally; sessions in Redis, so every node behind the load balancer sees the same state |
| 📦 | **Storage** | File storage on S3/MinIO, with metadata and folders in PostgreSQL |
| ⚡ | **Caching** | `@Cached` entity cache in Redis shared by every node; permission cache invalidated after commit; settings cache; in-memory domain map; immutable versioned assets and ETag/304 — [details](#-caching) |
| 🚀 | **Deploy** | `dart run` while developing, one self-contained binary from `dart compile exe` in production; the generated registry is committed, so a deploy needs no build step |
| 🛠️ | **Ops** | Audit log (`audit_log`) for every panel action including its outcome, logins and 2FA; `/health` health check; graceful shutdown; trusted-proxy client address; translations and time zones; console tools for emergencies |

> [!NOTE]
> **New in 0.3.0:** pages and entities come from a registry generated at build time
> (`lib/ignis_registry.g.dart`). One dev dependency (`build_runner`), one command, one line in `Ignis.start` —
> and the node compiles to a native binary. Upgrading from 0.2.x takes three steps, listed in the
> [changelog](CHANGELOG.md); the reasons are in [Why no `dart:mirrors`](#why-no-dartmirrors).

## Quick start

**Requirements:** Dart SDK ≥ 3.11, PostgreSQL ≥ 13 and Redis reachable from the node.

**1. Create the app** and add Ignis. `build_runner` is the only dev dependency — the registry generator ships
inside `ignis`:

```yaml
# pubspec.yaml
name: my_app
environment:
  sdk: ^3.11.0
dependencies:
  ignis:
    git: {url: https://github.com/PawelSzymanski89/ignis.git, ref: v0.4.0}
dev_dependencies:
  build_runner: ^2.4.0
```

**2. Declare a page.** Save the `Note` / `NotesPage` code from [At a glance](#at-a-glance) as `lib/notes.dart`,
and its template as `templates/notes.html`:

```html
{% extends layout %}
{% block heading %}Notes{% endblock %}
{% block content %}
<ul>{% for n in notes %}<li>{{ n.text }}</li>{% endfor %}</ul>
<form method="post">
  <input type="hidden" name="csrf" value="{{ csrf }}">
  <input name="text"> <button name="triggerAction" value="add">Add</button>
</form>
{% endblock %}
```

**3. Generate the registry** — and commit the file it writes:

```bash
dart pub get
dart run build_runner build      # writes lib/ignis_registry.g.dart
```

**4. Pass it to the engine** — the one line Ignis cannot write for you:

```dart
// bin/server.dart
import 'package:ignis/ignis.dart';
import 'package:my_app/ignis_registry.g.dart'; // generated by `dart run build_runner build`

Future<void> main() => Ignis.start(
      registry: ignisRegistry, // your pages and entities; the core ones are merged in
      brand: 'MyApp',
      templates: ['templates'],
      permissions: [('notes.view', 'View notes'), ('notes.edit', 'Edit notes')],
    );
```

**5. Start it:**

```bash
createdb ignis                     # an empty database; tables appear on first start

# every secret generated, the file readable only by you (it holds the database password and the key)
umask 077
cat > .env <<EOF
IGNIS_KEY=$(openssl rand -hex 32)
IGNIS_DOMAINS=localhost
IGNIS_DB_HOST=127.0.0.1
IGNIS_DB_PASS=$(openssl rand -base64 18)
IGNIS_REDIS_HOST=127.0.0.1
IGNIS_ADMIN_PASS=$(openssl rand -base64 18)
# required: behind a reverse proxy its address (IP/CIDR), `none` when clients connect directly. A wrong
# value makes every client look like the proxy — login limits lock out everyone, the log sees one IP
IGNIS_TRUSTED_PROXIES=127.0.0.1
EOF
chmod 600 .env

set -a && . ./.env && set +a
dart run bin/server.dart           # "Ignis listening on 127.0.0.1:8080" when ready
```

Then:

1. Set the same `IGNIS_DB_PASS` on the PostgreSQL role (`ALTER ROLE ignis PASSWORD '…'`).
2. Open `http://admin.localhost:8080/admin/login`. Browsers resolve `*.localhost` to the loopback and treat
   it as a secure context, so the `__Host-` cookies work without TLS.
3. Log in as `admin` with the `IGNIS_ADMIN_PASS` from `.env`. The panel will require a new password straight
   away. Without `IGNIS_ADMIN_PASS`, a random password is printed once to the console; a supplied one is
   never printed. **Notes** is in the menu under *Content*.

> [!TIP]
> Just want to look at the panel first? The repository itself is a runnable node with the core pages:
> `git clone https://github.com/PawelSzymanski89/ignis.git && cd ignis && dart pub get`, then step 5.

> [!IMPORTANT]
> The repository ships templates, the engine's own scripts (`/assets/ignis/`) and brand files, but **not** the
> admin theme's CSS/JS libraries (Bootstrap, htmx, icons). Point `IGNIS_ASSETS` at a directory with them
> (`libs/htmx/htmx.min.js`, `libs/bootstrap/…`); without them the panel renders, but unstyled and without
> htmx navigation.

Session cookies are `__Host-`-prefixed and `Secure`, so outside `localhost` browsers send them only over
HTTPS. Put the node behind a TLS reverse proxy (see
[SECURITY.md](SECURITY.md#sample-reverse-proxy-configuration)).

Everything else `Ignis.start` takes:

```dart
Future<void> main() => Ignis.start(
      registry: ignisRegistry,          // core pages and entities are added to it
      brand: 'MyApp',
      templates: ['templates'],         // searched before the package templates
      appAssets: ['web/assets'],        // your /assets/…, before IGNIS_ASSETS
      permissions: [('projects.view', 'View projects')],
      settingsSections: [
        Section('api', 'API', 'fe fe-key', 'Integration keys.', [Field('api_token', 'Token', type: FieldType.password)]),
      ],
      languages: ['en', 'pl'],          // i18n/<language>.json; the first is the default
      seed: seedMyApp,                  // runs after the core seed
      tasks: [Queue.start],             // background jobs started after boot
    );
```

## How it works

```mermaid
flowchart LR
    A["@Entity · @Page · @Action · @Cached<br/>anywhere under lib/"] -->|dart run build_runner build| G[generator<br/>ships in ignis]
    G --> R["lib/ignis_registry.g.dart<br/>committed"]
    R -->|"Ignis.start(registry: ignisRegistry)"| E[engine<br/>routes · tables · RLS · menu]
```

1. **Annotations.** `@Entity('table', pk:, unique:)` maps a class to a table; `@Cached` adds a shared Redis
   copy; `@Page(route, template:, requires:, label:, group:, order:)` makes a route and a menu entry;
   `@Action('name')` marks a method called on POST with `triggerAction=name`.
2. **Generator.** `ignis` carries a build_runner builder (`ignis|registry`) that applies itself to every
   package depending on `ignis` — no `build.yaml`, no stub file in your app. It reads **every `.dart` file under
   `lib/`**, so a new page or entity needs no import or barrel; `bin/` and `test/` are not scanned.
3. **Registry.** The output, `lib/ignis_registry.g.dart`, is ordinary Dart: constructor tear-offs, getter and
   setter closures per field, `@Action` calls, constant column defaults and per-class template getters.
   Commit it — `dart run` and `dart compile exe` need nothing else.
4. **Engine.** `Ignis.start(registry: ignisRegistry)` merges your registry with the core one and builds routes,
   the menu, tables, columns and RLS policies from it at start-up. Tables and columns are created, but columns
   are never dropped and their types are never changed.

The generator stops the build with file, line and class when:

- a page or entity has no **unnamed constructor without required parameters** (the engine calls it);
- a `@Page` class does not extend `PageEngine` (or `AdminPage` / `CustomerPage`), an `@Action` method is
  private or takes required parameters, or two entities share a class name.

It warns (and the build goes on) when a column **default is not constant** — `String status = 'new';` is
fine, a computed one gets no column default — and when a class or field is private (it is skipped).

`@Page(api: true)` is a JSON route without CSRF, so it must not authenticate by cookie: on an `AdminPage` /
`CustomerPage` subclass it stops the node at start-up, and it never receives the session, customer-session or CSRF
cookie nor the `Cookie` header. `@Page(methods: ['POST'])` returns 405 for other methods.
`@Page(maxBody:)` is the only way a route accepts multipart.

**Guard rails at start-up:**

- **No registry → no start.** Without `registry:` the node stops with a `StateError` that lists the three
  steps: `build_runner` in `dev_dependencies`, `dart run build_runner build` (or `watch`), and the
  `registry: ignisRegistry` line.
- **Stale registry → one warning, the start goes on.** The registry carries a fingerprint: a sha256 over the
  sorted paths and contents of every `lib/**.dart` (except the generated file). Under `dart run` Ignis
  recomputes it from the sources on disk; if anything under `lib/` was added, removed or edited since the
  last build, it prints **one** warning with the build / watch commands and runs on the registry as
  generated. An AOT binary has no sources, so it skips the check.

## Development loop

```bash
dart run build_runner watch      # leave it running: the registry is rebuilt after every save
dart run bin/server.dart         # restart the node to pick up changes
```

Forgot `watch`? The stale-registry warning at start-up says so, with the command to run.

## Deployment and AOT

```bash
dart compile exe bin/server.dart -o server
```

- The registry is committed, so the build machine and CI need **no code generation** — `dart pub get` and
  `dart compile exe` are enough. To fail CI when someone forgot to regenerate:

  ```bash
  dart run build_runner build && git diff --exit-code -- lib/ignis_registry.g.dart
  ```

- The generator's dependencies (`analyzer`, `build`, `source_gen`) are build-time only:
  `package:ignis/ignis.dart` never imports them, so they are not in the binary.
- A compiled binary has no package config, so set `IGNIS_PACKAGE_ROOT` to a copy of the ignis package
  directory (its `templates/`, `i18n/`, `web/`). Your own `templates` / `appAssets` paths resolve against the
  working directory as before.
- `tool/aot_smoke.sh` compiles `bin/server.dart` and checks the binary against `dart run` on a fresh
  database: `/health`, sign-in, panel pages, a CRUD round-trip, identical HTML.

## Templates

- `{{ obj.field }}` on a `@Page` or `@Entity` object is served by the **getters generated into the registry**
  (every public field and getter, base classes included) — the same under `dart run` and in the binary.
- Maps work as always: `{{ m.name }}`.
- An object outside the registry has no generated getters, so `{{ o.name }}` renders empty — pass a Map
  (`{'name': p.name}`) instead.
- Every string is HTML-escaped unless wrapped in `Html(...)`. A file with the same name in your
  `templates` / `appAssets` directories overrides the package one.

## Why no `dart:mirrors`

Up to 0.2.x Ignis discovered pages and entities at runtime with `dart:mirrors`. 0.3.0 drops it completely:

- **Deprecated.** In the Dart 3.14 SDK the library is marked `@deprecated` — its own documentation says it
  "will be removed in a future release" — and the analyzer reports every `import 'dart:mirrors'` as
  `deprecated_member_use`. Ignis 0.2.1 under `dart analyze --fatal-infos` on Dart 3.14 fails with five such
  infos, which turned CI red.
- **Pinned to JIT.** `dart compile exe` refuses the import (`Dart library 'dart:mirrors' is not available on
  this platform`), and Flutter does not ship the library at all. A mirrors-based Ignis could only run as
  `dart run`, with a full SDK on the server.
- **One binary now.** Measured on this repository's own node (`bin/server.dart`, core pages only): Dart
  3.14.1, Linux x64, Intel Core i5-10500T, local PostgreSQL 18 and Redis 8, a fresh database each run; time
  from process start to the first `/health` 200, schema creation and seed included; three runs each.

  | | Start → `/health` 200 | What you ship |
  |---|---|---|
  | `dart run bin/server.dart` (JIT) | 6.6–6.7 s | sources + Dart SDK + pub cache |
  | `dart compile exe` binary (AOT) | 0.65–0.74 s | one 11.1 MB file (11,075,608 bytes) |

- **The price:** `build_runner` in `dev_dependencies`, `dart run build_runner build` (or `watch`), and one
  `registry: ignisRegistry` line. The line cannot be avoided: Dart runs no code when a library is imported,
  so the generated file cannot register itself, and a conditional import inside `ignis` can only choose
  between files `ignis` already has — never a file of your app. Passing the registry is how your classes
  reach the engine.

## ⚡ Caching

Ignis keeps **one cache layer in Redis that every node shares** and a few small layers in node memory and
in HTTP. All of them work with zero configuration. Each one has a clear owner and a clear invalidation rule.

| Layer | What | Where it lives | Invalidation |
|---|---|---|---|
| 🪞 Entity cache | Rows of `@Cached` entities | Redis `entity:<Type>:<id>` | Dropped on `save`/`insert`/`upsert`/`delete` (right away and after the transaction ends); refilled by the next read; optional TTL |
| 🔑 Permissions | Effective permissions of an account | Redis `perm:<login>`, 15 min | `Permissions.invalidate` / `invalidateMany` after the transaction ends |
| ⚙️ Settings | Settings of one service (secrets **encrypted**) | Redis `settings:<service>`, 60 s | Dropped after every `saveSetting` |
| 🌐 Domain map | Host → service, name, active flag | Node memory | Re-read every `Tenants.refreshing` (30 s) or after `Tenants.refresh()` |
| 📦 Static assets | `/assets/…` with `?v=<content hash>` | Browser / CDN | The URL changes with the file |
| 🧾 Conditional JSON | `conditionalJson(...)` responses | Browser / client | Weak ETag of the content → 304 |
| 🎫 Sessions *(shared state)* | Panel `sess:` and customer `csess:` sessions | Redis, keyed by `sha256(token)` | Logout, password change, TTL |

### 🪞 `@Cached` entity cache

Put `@Cached` next to `@Entity` and the row is copied to Redis under `entity:<Type>:<id>`, so every node
reads the same copy:

- **Read-through:** `readEntity<T>(id)` / `Orm.read<T>(id)` checks Redis first. On a miss it reads the
  database and fills the copy — only if no write dropped the key meanwhile (the reader reserves it with
  `SET NX` before the query).
- **Invalidate on write:** `saveEntity` / `Orm.save`, `Orm.insert`, `Orm.upsert` and `Orm.delete<T>(id)`
  never write the copy; they delete the key right away and again after the transaction ends (commit or
  rollback). Until then the writing transaction reads the database directly (it sees its own writes) and does
  not fill the copy, so a rolled-back write or savepoint never reaches Redis.
- `DateTime` fields are stored in UTC. An entry that cannot be read back counts as a miss and is dropped.
- `@Cached(ttl: 3600)` expires the copy after an hour. `ttl: 0` (the default) means no expiry.
- `readEntitys<T>()` / `Orm.readAll` and `Orm.pick` always go to the database.

Use `@Cached` for global, rarely-changing data (dictionaries, platform config).

> [!IMPORTANT]
> `@Cached` is for **global data** — dictionaries, platform configuration. An entity on a table under
> row-level security (a `service` column, or an engine grant table such as `user_packages`) cannot be
> cached: the node refuses to start with
> `StateError: @Cached on an RLS-scoped entity (…) would bypass service isolation`.
> Tenant data never lands in the shared cache.

```dart
@Entity('currencies', pk: 'code')
@Cached(ttl: 3600)            // Redis copy lives for an hour; no `service` column — global data
class Currency {
  String code = '';           // app-assigned key → Orm.insert / Orm.upsert
  String name = '';
  int decimals = 2;
}

@Page('/v1/currencies/{code}', api: true)
class CurrencyApi extends PageEngine {
  @override
  Future<bool> processData() async {
    final c = await readEntity<Currency>(get('code') ?? '');   // Redis first, then the database
    if (c == null) return notFound();
    return conditionalJson({'code': c.code, 'name': c.name, 'decimals': c.decimals}, maxAge: 60);
  }
}
```

### 🔑 Permission cache

`Permissions.forUser(login)` caches the effective permissions in `perm:<login>` for 15 minutes. Every
change to a package, grant or assignment calls `Permissions.invalidate` / `invalidateMany`. The keys are
dropped through `Db.afterTransaction`, so **after** the request transaction ends. If they were dropped
before COMMIT, a parallel request on another node could rebuild the cache from the old state. If Redis is
down, permissions are computed from the database, just slower.

```dart
await Permissions.invalidate('alice');           // one account
await Permissions.invalidateMany(['bob', 'eve']); // e.g. holders of a changed package
```

### ⚙️ Settings cache

`Permissions.settings(service)` caches one service's settings in `settings:<service>` for 60 s. Redis holds
**only the encrypted values** of secrets — plaintext exists only in node memory.
`settings(service, secrets: false)` skips secret keys and decryption altogether; the panel uses it for the
template model. `saveSetting` drops the key **after** the database write.

### 🌐 Domain map

The tenant comes from `Host`, and the node resolves it from an **in-memory map of all domains**:

- One query reloads the whole map every `Tenants.refreshing` (30 s by default). Parallel requests wait for
  that one load instead of each running its own.
- An unknown or malformed `Host` costs **no database query and no Redis key**, so random headers cannot
  flood the pool.
- If a reload fails, the node keeps the previous map and tries again 5 s later.
- After changing services or domains, call `Tenants.refresh()`. This node reloads on the next request, the
  others within `refreshing`.

### 📦 HTTP caching

| Response | `Cache-Control` | Revalidation |
|---|---|---|
| `/assets/…?v=<hash>` | `public, max-age=31536000, immutable` when `<hash>` is the served file's digest, otherwise `no-cache` | — |
| `/assets/…` without `?v` | `no-cache` | Weak ETag → 304 |
| `Mount(...)` file matched by `immutable` | `public, max-age=31536000, immutable` | Weak ETag → 304 |
| Other `Mount(...)` files | `public, max-age=<maxAge>` (300 by default) | Weak ETag → 304 |
| `conditionalJson(obj, maxAge: n)` | `private, max-age=n` | Weak content ETag → 304 |
| Dynamic HTML / JSON | `no-store`, unless the page sets its own | — |

- The renderer appends `?v=<md5, 10 hex>` to every `href="/assets/…"` and `src="/assets/…"` in your
  templates automatically. The hash is computed once per file per process.
- Text assets are gzipped once and served from memory (files up to 1 MB).

```dart
Ignis.start(
  mounts: [
    Mount('/sdk/', 'web/sdk',
        maxAge: 600,
        immutable: (path) => path.startsWith('v1.4.0/')), // versioned directory → cached for a year
  ],
  // …
);
```

### ⚖️ Why it scales

Everything that must agree across nodes — sessions, permissions, settings, entity copies — lives in
Redis. So **every node sees the same state**, and a plain round-robin load balancer works without sticky
sessions. Every Redis call has a **2 s limit**. After an error the connection is dropped and the next call
opens a new one, so a Redis restart does not require restarting the nodes.

## Architecture

```mermaid
flowchart LR
    B[Browser<br/>htmx] -->|HTTPS| P[Reverse proxy<br/>TLS, HSTS]
    P -->|Host, X-Forwarded-For| N1[Ignis node]
    P --> N2[Ignis node]
    subgraph node [Ignis node — one isolate]
        T[Tenant from Host<br/>engine/tenant.dart] --> L[Page lifecycle<br/>CSRF, permissions, @Action]
        L --> R[Jinja render<br/>escape by default]
        L --> D[(Db.inContext<br/>transaction + ignis.service)]
    end
    N1 -.- node
    D --> PG[(PostgreSQL<br/>RLS fail-closed)]
    L --> RD[(Redis<br/>sessions, caches, locks)]
    L --> S3[(S3 / MinIO<br/>files under t&lt;service&gt;/)]
```

Each request resolves its tenant from `Host` exactly once. It then runs inside a database transaction where
`ignis.service` is set locally, so the RLS policies see the right tenant. The response goes out only after
that transaction commits and its connection has gone back to the pool.

## Configuration

All configuration comes from environment variables read by the engine. The required ones are `IGNIS_KEY`,
`IGNIS_DOMAINS`, `IGNIS_DB_HOST`, `IGNIS_DB_PASS`, `IGNIS_REDIS_HOST` and `IGNIS_TRUSTED_PROXIES`.

<details>
<summary><b>All environment variables</b></summary>

| Variable | Default | Meaning |
|---|---|---|
| `IGNIS_KEY` | **required** | 64 hex chars; AES-GCM key for secrets and HMAC key for signatures. The node refuses to start without it |
| `IGNIS_KEY_PREVIOUS` | — | the previous `IGNIS_KEY` during a rotation: secrets and TOTP seeds it encrypted stay readable until `bin/rekey.dart` re-encrypts them. An invalid value stops the node |
| `IGNIS_DOMAINS` | **required** | comma-separated system domains; `admin.<domain>` is the platform panel |
| `IGNIS_DB_HOST` | **required** | PostgreSQL host |
| `IGNIS_DB_PASS` | **required** | PostgreSQL password |
| `IGNIS_DB_PORT` | `5432` | PostgreSQL port |
| `IGNIS_DB_NAME` | `ignis` | database name |
| `IGNIS_DB_USER` | `ignis` | database role — a plain role owning the tables; a superuser or `BYPASSRLS` role is refused at start-up (RLS would not apply) |
| `IGNIS_DB_POOL` | `16` | connection pool size |
| `IGNIS_DB_SSL` | `disable` | `verify-full` = TLS with certificate and host verification, `require` = TLS without verification (warned about for a remote host); other values abort start-up |
| `IGNIS_REDIS_HOST` | **required** | Redis host |
| `IGNIS_REDIS_PORT` | `6379` | Redis port |
| `IGNIS_REDIS_PASS` | — | Redis password |
| `IGNIS_REDIS_TLS` | — | `1` = TLS to Redis, verified against system CAs |
| `IGNIS_PORT` | `8080` | HTTP listen port |
| `IGNIS_NODE` | `node` | node name in logs, locks and the audit log; must be unique per node (warning when unset) |
| `IGNIS_REQUIRE_RUNTIME_ROLE` | unset | `1` = refuse to start (before any DDL) when the database role owns engine tables (serving nodes on a runtime role; `tool/runtime_role.sql`); any other non-empty value refuses to start |
| `IGNIS_SCHEMA` | `update` | `update` creates tables and columns, `validate` and `none` only check. Serving nodes: `validate` on a runtime role without table ownership ([SECURITY.md](SECURITY.md#runtime-database-role)) |
| `IGNIS_ASSETS` | `web/assets` | directory with the theme's static files (`/assets/…`) |
| `IGNIS_TRUSTED_PROXIES` | **required** | IPs/CIDRs whose `X-Forwarded-For` is trusted; `none` (any case) = no reverse proxy. Unset, empty, a non-address entry or a `/0` prefix stops the node |
| `IGNIS_TIMEOUT_S` | `120` | whole-request deadline in seconds |
| `IGNIS_SHORT_TIMEOUT_S` | `15` | deadline for routes without `maxBody` (plain forms) |
| `IGNIS_UPLOAD_BUDGET_MB` | `64` | total size of multipart bodies buffered at once |
| `IGNIS_API_BODY_BUDGET_MB` | `64` | total size of `api: true` bodies held at once (on the wire and after gzip); above it `503`; not an integer ≥ 1 = no start |
| `IGNIS_MAX_INFLIGHT` | `512` | requests handled at once; above it `503` with `Retry-After` (logged, at most one line a second); a value other than an integer ≥ 1 stops the node |
| `IGNIS_BCRYPT_THREADS` | CPU count | concurrent bcrypt isolates |
| `IGNIS_BIND` | `127.0.0.1` | listen address (`0.0.0.0` or a private address when the proxy is on another host) |
| `IGNIS_HSTS` | — | `1` makes the node send `Strict-Transport-Security` |
| `IGNIS_ADMIN_PASS` | random | password of the `admin` account created on the first start (min. 10 characters, else the seed aborts) |
| `IGNIS_S3_HOST` | — | S3/MinIO host; without it file storage is disabled |
| `IGNIS_S3_PORT` | `9000` | S3 port |
| `IGNIS_S3_KEY` / `IGNIS_S3_SECRET` | required with `IGNIS_S3_HOST` | S3 credentials |
| `IGNIS_S3_BUCKET` | `ignis` | bucket name |
| `IGNIS_S3_SSL` | — | `1` = HTTPS to S3 with certificate verification |
| `IGNIS_S3_TIMEOUT_S` | `60` | deadline of one transfer to S3 |

</details>

<details>
<summary><b>Console tools (<code>bin/</code>)</b></summary>

| Tool | Purpose |
|---|---|
| `server.dart` | the core node |
| `account.dart list \| disable-2fa <login> \| password <login>` | emergency 2FA removal or password reset. The password is read from stdin and the action is written to the audit log |
| `rekey.dart` | after an `IGNIS_KEY` rotation re-encrypts settings secrets and TOTP seeds under the current key; idempotent, prints how many records it changed and exits with 1 if any is unreadable with both keys |
| `purge.dart list \| delete <slug>…` | removes a service with its rows, S3 objects, sessions and caches. Asks for confirmation and writes to the audit log |
| `smoke_panel.dart <panel-url> <login>` | logs in and opens every panel route. The password is read from stdin; any 5xx makes it exit with 1 |

</details>

### Content-Security-Policy

Every HTML response — pages, error pages and static `.html` files — gets a strict CSP in the
`Content-Security-Policy` header (`default-src 'self'; script-src 'self'; …`). The package layouts repeat the
same policy in a `<meta>` (`{{ csp }}`, without `frame-ancestors`, which a meta CSP ignores). An app can add
sources per directive at start-up; they are merged into the base policy:

```dart
await Ignis.start(
  extraCsp: {
    'img-src': ['https://images.example.com'],
    'font-src': ['https://fonts.example.com'],
    'script-src': ["'wasm-unsafe-eval'"], // WebAssembly
    'worker-src': ['blob:'],
  },
);
```

Only known fetch/navigation directives are accepted; sources must be a host/scheme or a quoted CSP keyword
(no `;`, `,`, spaces or newlines). `'unsafe-inline'` and `'unsafe-eval'` are refused in `script-src*`.
Invalid values throw `ArgumentError` and the node does not start. `Engine.buildCsp(extra)` returns the
resulting policy for inspection.

## Testing

```bash
dart run build_runner build   # after changing anything under lib/ (registry_parity_test checks it)
dart analyze --fatal-infos
for t in test/*_test.dart; do dart run "$t" || echo "FAIL $t"; done
```

Tests that need PostgreSQL and Redis (RLS on a role without `BYPASSRLS`, seed, audit log) run on
throw-away instances with:

```bash
tool/pg_test.sh
tool/aot_smoke.sh     # after pg_test.sh: dart compile exe, /health, sign-in, panel pages, CRUD — binary vs JIT
```

The `*_pg_test.dart` files matched by the loop above skip themselves without `IGNIS_DB_HOST` (three
Redis-only session tests check `IGNIS_REDIS_HOST` instead). Engineering rules are in [QUALITY.md](QUALITY.md).

## Status

Version **0.4.0** — security hardening (`api: true` routes get no session/CSRF cookies, `Storage.read` takes the
service; see the [changelog](CHANGELOG.md)). 0.3.0: pages and entities from a registry generated at build time, so a node
also runs as a native binary; apps take a one-time step (`build_runner`, generate, pass `registry:`) — see the
[upgrade notes](CHANGELOG.md). Earlier: 0.2.2 was a Dart 3.14 compatibility release, 0.2.1 a
hardening follow-up to 0.2.0, after the first public release (0.1.0, extracted from a
production multi-tenant panel) and 0.1.1 (configurable Content-Security-Policy). 0.2.0 made
`IGNIS_TRUSTED_PROXIES` required (`none` = no reverse proxy); 0.2.1 refuses `api`/`cors` routes on cookie-
authenticated pages — see the upgrade notes in the [changelog](CHANGELOG.md). The API (`Ignis.start`, `@Page`,
`@Entity`) may still change before 1.0. Identifiers, the database schema and the default UI language are
English; a Polish translation of the panel ships in `i18n/pl.json`. See the [changelog](CHANGELOG.md).

## Roadmap

Open items already recorded in [SECURITY.md](SECURITY.md#known-gaps-and-debt) — directions, not promises:

- **Key rotation with a key id** — today rotation is two-key (`IGNIS_KEY_PREVIOUS` + `bin/rekey.dart`), ciphertexts carry no key id.
- **Open decisions:** tenant subdomains vs. a separate registrable domain, per-tenant namespacing of staff
  logins, and a breached-password check.
- **API stabilisation** of `Ignis.start`, `@Page` and `@Entity` towards 1.0.

## Contributing

Issues and pull requests are welcome. Before you open a PR, read [QUALITY.md](QUALITY.md) — it is short and
every rule in it comes from a real incident. In short: the engine stays bare (domain features belong in the
application), one generator and no other codegen, every domain query filters by `service`,
`dart analyze --fatal-infos` is clean, all tests are
green, and the commit message says **what and why**.

## Security

The threat model, tenant isolation (RLS), authentication, CSP, secrets, network edge and known gaps are
described in [SECURITY.md](SECURITY.md). Please report vulnerabilities **privately** through
[GitHub Security Advisories](https://github.com/PawelSzymanski89/ignis/security/advisories/new) — never in a
public issue.

## License

MIT — see [LICENSE](LICENSE).

## Support

If Ignis saves you time, you can support its development:

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-cygan-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/cygan)

---

<div align="center">
<sub>Made with 🔥 in Dart</sub>
</div>
