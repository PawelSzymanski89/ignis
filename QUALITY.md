# Quality — how we work with this code

Rules distilled from what worked in this project and what came back to bite us. They are not general
advice; each one is here because of a concrete incident.

## Before writing code

1. **Check whether it already exists.** Before adding a table or a field, `grep` for the name — a column
   lying unused in the database is more common than a missing one.
2. **The engine stays bare.** A domain feature (invoices, payments, integrations) belongs to the
   application, not to `ignis`. The core gets a mechanism that every application needs.
3. **The shortest solution that works.** No interface with one implementation, no factory
   for one product, no configuration for a value that never changes.
4. **Understand the flow before shrinking the diff.** The smallest change in the wrong place is a second bug,
   not a saving.

## Hard rules

- ⛔ **One generator.** The only codegen is `ignis|registry` (`lib/builder.dart`) → `lib/ignis_registry.g.dart`:
  commit it, regenerate with `dart run build_runner build` (or keep `watch` running). No other builders, and
  nothing in `package:ignis/ignis.dart` may import `analyzer` / `build` / `source_gen` — they would end up in
  the binary. Why there is a generator at all: README, "Why no `dart:mirrors`".
- **Every domain query filters by `service`.** The parameter is required, not defaulted —
  with a default value the code compiles and quietly shows someone else's data.
- **Secrets only through `password`/`file` fields** in settings sections (`Section`/`Field`) —
  they are then encrypted automatically.
- **User data never in JavaScript.** `data-*` + a handler, never `onclick="...{{ x }}..."`.
- **A new page = `@Page` with `requires`.** The menu is built from the registry, so the permission
  and the visibility are one decision.

## Tests

Most tests run **without a database or network** — pure functions and assertions, run with
`dart run test/<file>.dart`. No framework. The `*_pg_test.dart` ones need PostgreSQL and Redis
and run on throw-away instances via `tool/pg_test.sh`.

What has tests: permission logic, routing and route parameters, actions and gates, renderer escaping,
listing and CSV, periods, formats and time zones, translations, TOTP and JWT (RFC / openssl vectors), crypto,
the audit log (secret filter), front accounts, shutdown, and the migration of a pre-release schema.

**After a change in the panel, walk through it signed in**: `bin/smoke_panel.dart <url> <login>` (password from stdin)
opens every route from the registry and shows the response codes. This is not overkill — an
`ORDER BY` with an alias broke whole pages for a month, because `dart analyze`
does not see it, tests do not touch the SQL, and nobody opened those pages signed in.

**New non-trivial logic leaves behind one runnable assertion.** One-liners
do not need a test.

**The menu is built from `@Page`, so the order lives in the annotation, not in the template.**
Every item declares a `group` (section heading) and an `order` numbered in TENS
within the group — inserting a page in the middle then needs no renumbering of its neighbours.
Two pages with the same number were placed in whatever order the classes happened to be
found. The core uses the `System` section; the application adds its own.
No group = the start section ("Panel"). A page without a `label` is outside the menu on purpose
(it is entered from a specific place, like "My account" from the profile).

**A cross-cutting mechanism is hooked in one place.** The audit log is written
in `engine.dart`, right after the action call — not in thirty pages. If every page
had to remember the entry, the first new one would drop out of the audit and nobody would notice until
the question "who changed this". The same rule applies to the `service` filter and to renderer escaping.

**Automation is guarded by the database, not by a condition in code.** Whatever runs in the background (`tasks:`
in `Ignis.start`) will wake up twice — after a node restart, when it coincides with a manual
click, with two nodes at once. A Redis lock lowers the chance, but it is the unique
index that guarantees there will be no duplicate.

## Templates (jinja 0.6.7) — traps we have already fallen into

| Trap | Symptom | How to write it |
|---|---|---|
| positional argument for a parameter with a default value | `TypeError` at render | `macro(x, w=value)` or a parameter without a default |
| slicing `list[:3]` of a list shorter than 3 | `RangeError` | `{% for %}` + `{% if loop.index <= 3 %}` |
| `{% import %}` outside a block in a template with `{% extends %}` | macro = null | import **inside** the block |
| `.get()` on a map | `NoSuchMethodError` | `{{ m.key }}` or `|default('')` |
| no autoescape | XSS | `Renderer` escapes; `Html(...)` only for trusted HTML |

## Comments

A comment says **why**, not what. Especially: why it is done this way when a simpler
solution looks sufficient. Example: "the sequence number must be taken in a transaction
with an advisory lock, because after moving to a connection pool two parallel requests got the same
number". Without that sentence someone will simplify it back.

Deliberate simplifications are marked `// ponytail:` with the ceiling and the way out
(`// ponytail: LIMIT 500 — paginate when a service exceeds 500 accounts`).

## Database schema

Auto-schema adds columns at start-up — it **does not drop** them or change types, so a field
removed from an entity stays in the database until someone decides by hand.

## Before committing

- [ ] `dart analyze` clean
- [ ] all tests green
- [ ] new logic has an assertion, a deliberate simplification has `// ponytail:`
- [ ] queries filter by `service`, secrets do not go back to the browser
- [ ] the commit message says **what and why**, not "fixes"; unverified things marked ⚠️
- [ ] README/SECURITY updated if the facts changed

## Debt

Debt is recorded in [SECURITY.md](SECURITY.md) (the "Known gaps" section) or with a
`// ponytail:` comment in code. Undescribed debt is debt nobody will pay off — and after half a year
nobody remembers whether it was a decision or an oversight.
