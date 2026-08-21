# Project Instructions for AI Agents

eiermann is a Flutter + PocketBase app for **Gelegemanagement** — managing
city-pigeon clutches: which buildings a group has access to, which nests are in
them, when each was last checked, and what was found. It replaces a WhatsApp
history in which the last known state of a nest is unknowable without asking
somebody.

The product and technical concept lives in `docs/concept.html` (rendered) and
`docs/concept-digest.md` (the working reference — read the digest, not the
HTML). Everything below is what an agent needs that the concept does not say.

## Working language

The domain vocabulary is **German**, and so is every user-facing string: Spot,
Nest, Gelege, Besuch, Erkundung, Koordination. Code identifiers and comments are
English; ARB strings, issue titles and `bd close --reason` text are German. The
German ARB is the gen-l10n **template** (`app_de.arb`), not a translation of an
English original — see "Localisation" below.

## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full
workflow context and commands.

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or
  markdown TODO lists
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files
- Issues are organised in phase epics. **Phase 04 (`eiermann-jbk`) is the
  cut**: after it the app replaces the WhatsApp history and all three named
  field problems are solved. Everything from Phase 05 on is addition.

**Architecture in one line:** issues live in a local Dolt DB; sync uses
`refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export.
See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md.

## Repo layout

```
apps/eiermann/          the Flutter app (a pub workspace member)
  lib/config/           zugvogel bindings — the injection seams, wired once
  lib/features/<name>/  one directory per feature: data, providers, screens
backend/pocketbase/
  pb_migrations/        numbered, immutable, applied in filename order
  pb_hooks/             *.pb.js are eiermann's; zv_*.js are vendored, DO NOT EDIT
  tests/                run.sh boots a throwaway instance and asserts the rules
docs/concept-digest.md  the working reference for every product decision
```

`zugvogel` is a sibling repo (`../zugvogel`) holding everything shared with
`federfall`, the pigeon-rehab app this one is modelled on. Its packages come in
as **git dependencies pinned to a commit hash** — never a tag: a tag can be
re-pointed, pub caches by ref, and two machines then resolve the same
declaration onto different code. There are deliberately no releases; a
release-please PR stands open as a changelog and **is never merged**.

When a fix belongs in shared code, make it in `../zugvogel`, push, and bump the
hash in `pubspec.yaml` here. Do not fork a zugvogel file into this repo.

## Build & Test

```bash
# Flutter — run BOTH from the repo ROOT, never from apps/eiermann
flutter analyze                      # see trap 21 below
flutter test                         # apps/ + any local packages
flutter gen-l10n                     # after EVERY ARB change

# Backend rules — boots a throwaway PocketBase, applies migrations, asserts
./backend/pocketbase/tests/run.sh

# The dev stack. federfall's dev stack owns 8090, so pick another port:
EIERMANN_PORT=8091 docker compose up -d --build
# A coordinator is seeded from the compose env: dev@eiermann.local / DevPass12345!
```

Generated code (`*.g.dart`, `*.freezed.dart`, `lib/l10n/gen/`) is **gitignored
and built**, never committed. A stale generated file produces errors that look
like something else entirely.

## Localisation

`apps/eiermann/lib/l10n/arb/app_de.arb` is the gen-l10n **template**. Two
consequences that have each cost an hour:

- **Never add a `localeName` key.** gen-l10n generates a `localeName` getter
  itself, and an ARB key of that name collides with it — the failure is a
  generated-file compile error that does not mention the ARB at all.
- A new **non-ASCII character** is only safe if the bundled font set covers it.
  Web has no system fonts: an uncovered codepoint makes the engine fetch a Noto
  slice from `fonts.gstatic.com`, the CSP blocks it, and the engine retries on
  every layout of that text — one arrow in a string produced an endless console
  error stream on a deployed federfall instance. Both halves (bundled asset and
  `fontFamilyFallback` entry) are pinned by a test in zugvogel_ui.

## The three injection seams

zugvogel holds no strings, no colours and no configuration, so that federfall
and eiermann can share the code that surrounds them. All three are bound in
**one place** — `apps/eiermann/lib/config/zugvogel_bindings.dart`, called from
`main()` — and in `test/flutter_test_config.dart` for tests, which is the only
hook that reaches every test in a package.

1. `defaultZugvogelStrings` — a resolver taking a `BuildContext`, so a locale
   change stays reactive. Do not capture the strings in a `final`.
2. `ZugvogelSemantics` — the `good`/`warning`/`critical` and categorical
   palettes, as a `ThemeExtension`. The app's seed colour is
   `AppTheme.seed`; a hard-coded `Colors.red` anywhere is a bug a sweep test
   catches.
3. `defaultPbClientConfig` — server URL, service name, version. Requiring an
   override instead of a settable default broke 173 tests across 86 files in
   federfall; the settable default is deliberate.

There are **sweep tests** over the source for each boundary. They exist because
a screen written next month would reintroduce the problem in silence, and a
per-screen test cannot cover code that does not exist yet. If a sweep fails,
fix the code — do not extend the allowlist without a reason written next to it.

**When you add a guard test, plant a canary.** Write the violation, watch the
guard fail, then remove it. A guard that has never failed proves nothing: one
of these "passed" for an afternoon because the formatter had moved the argument
it was searching for.

## PocketBase

### Migrations are historical facts

A migration is immutable once applied. **Never edit an applied migration file**
— add a new one. This is also why migrations are *copied templates* from
zugvogel rather than shared code: federfall created `organisations` under
`1700000001`, and the same number here means something else.

### The security model

Every access rule opens with the same clause, and the rule suite sweeps for it:

```
@request.auth.id != "" && @request.auth.is_active = true && role != null
```

Three properties hold for every client-writable collection, asserted as sweeps
so they also cover collections nobody has written yet:

- an authenticated, **active** caller with a **non-null role**;
- **org scope**, taken from the **stored** row;
- an update rule that **pins `org`**, so a record cannot be re-tenanted.

Then the parts that are easy to get wrong:

- **A plain field reference in an UPDATE rule resolves against the STORED
  record.** The rule checks the old value and ignores the incoming one. So:
  access rules are the security boundary; **invariants need a hook**. Access
  rules alone cannot prevent privilege escalation — the guard in `main.pb.js`
  is not optional.
- Guard a field against client writes with `@request.body.x:isset = false`.
- A **view does not inherit the rules of the table under it.** State them on
  the view. Forgetting this is how a carefully scoped table becomes public.
- A **cascading delete destroys a forgotten collection's rows and answers
  200.** Every collection with a `spot` or `nest` relation belongs in the
  delete-effect registry, and the suite fails in both directions: an entry with
  no cascade, and a cascade with no entry.

### Testing the rules

`backend/pocketbase/tests/run.sh` boots a throwaway instance. Two shapes fool a
suite into passing on a public database, so use the harness helpers:

- **A LIST is filtered, not refused.** An anonymous read of a fully private
  collection returns **200 with an empty `items` array**. Asserting
  `status >= 400` therefore passes on a completely open database. Use
  `h.reads_nothing(collection)`; it checks the items, and takes the
  single-record path when given a `record_id`.
- **A DELETE answers 204.** `status == 200` is a test that fails against a
  working server — which is worse than no test, because somebody then "fixes"
  the rule. Use `h.ok(status)`.
- The factory **rate-limits `*:auth` to 2 requests per 3 seconds**. Exceeding
  it makes a login return no token; an empty token reads as *anonymous*, and an
  anonymous LIST returns 200 with zero rows — indistinguishable from a working
  rule. The shared harness backs off on 429; do not write your own login.

### JSVM traps

The hook runtime is not Node and not a browser. Each of these has cost real time:

- **Every handler runs in an isolated context.** A file-level `const` or
  helper is **not visible inside the handler** — the failure is a
  `ReferenceError` at request time, surfacing as a generic 400 on an ordinary
  operation. Put `require()` **inside** the handler, in the absolute
  `${__hooks}` form, and declare constants inside it too.
- `record.get("x")` **throws** "invalid key path - missing key" for an absent
  key. Read request bodies via `e.requestInfo().body`.
- A **JSON field** hands JS a `types.JSONRaw` byte array. Every property access
  is `undefined` and the code falls silently into its default. Keep one JSON
  field and one reader (`zv_org.js`).
- A **computed view column** falls back to type `json`, so `getString()`
  returns `"value"` *with quotes*. Ask the collection for `field.type()` and
  decode; never sniff per value — a city named `true` also parses as JSON.
- Set a password with **`setPassword()`**. `record.set("password", …)` silently
  does nothing. `verified` is a protected system field.
- There is **no global `onServe`**.
- `onBootstrap` + `e.next()` **does not guarantee migrations have been
  applied**. On a fresh data directory the bootstrap hook queried collections
  `--automigrate` had not created yet, so it failed on first boot and quietly
  worked on the second. The dev stack therefore runs `migrate up` as its own
  step before `serve`.
- A **view's `viewQuery` is parsed by PocketBase itself** and follows neither a
  `--` comment nor an expression spanning newlines: both come back as "invalid
  identifier parts". Every computed column is one line, however long, with the
  reasoning in a JS comment above it.
- An **`ApiError`'s `data` cannot carry a value.** PocketBase coerces every leaf
  of it into `{code, message}` at any depth, so `{stage: "untouched"}` arrives
  as `{stage: {code: "validation_invalid_value", …}}`. It is structurally a
  field-name → validation-error map. A hook that needs to tell the client
  something specific must put it in the `message` — which means the message
  carries no untranslated wire value, because it is German prose. The client
  already holds the record it tried to write.
- `cronAdd` jobs are invisible to the rule suite — nothing can trigger them.
  They get a separate harness with a rewritten schedule. A window measured in
  days cannot be reached by backdating, because `created` belongs to the
  server; make the window vanishingly small in the test instead.

### Dev-stack notes

Compose **appends** port lists rather than replacing them, hence
`EIERMANN_PORT`. `serve --dev` prints logs and SQL to stdout; without it
PocketBase writes log records to an internal table and `docker compose logs`
shows nothing, making a failing hook indistinguishable from one that never ran.

## Dart & Flutter

- **Dates.** PocketBase timestamps are UTC, and neither `DateFormat` nor
  `MaterialLocalizations` converts. In CET everything after 22:00 UTC shows the
  previous day — invisible on a UTC CI machine, and it reaches users one screen
  at a time. Route **every** `DateTime`→text conversion through
  `formatLocalDate`. A sweep test enforces it.
- **Filters.** Never interpolate user input into a filter string. The query
  surface accepts only `PbFilter`, produced only by `filterExpr`, so the
  mistake is a compile error.
- **Paging.** `?page=` over a list that grows while being read skips and
  duplicates rows. Use keyset pagination and zugvogel_ui's `PagedListTail`
  (`onLoad`/`onRetry`) at the end of the list. Debounce search fields — one
  keystroke is one request otherwise.
- **Enums** get an explicit `wire` value: the exact string PocketBase stores.
  A Dart rename is then wire-safe.
- **A never-set geoPoint arrives as `{lon: 0, lat: 0}`** — a real place in the
  Gulf of Guinea. `GeoPoint.fromPb` reads it as `null`; use that, do not parse
  coordinates by hand.
- **No code generation in zugvogel**, ever: `build_runner` cannot run inside a
  fetched git dependency. Its providers are hand-written, which means a
  hand-written `name:` on every one (a sweep test checks). In *this* app
  codegen is fine — but run it.
- **Idempotency.** One Besuch = one route, one transaction, one idempotency
  key. Multiple records over multiple requests means an abort mid-way leaves a
  state indistinguishable from an intention.
- **Audit entries store text snapshots**, not ids to look up later: the target
  may be renamed or deleted, and then the entry describes the past wrongly. An
  id without a label next to it is a bug.
- **One derivation.** The visit rhythm gets derived in exactly one place and
  every writer calls it — a shared hook library, once Phase 03 writes it. Two
  derivations drift.
  After-success hooks re-read the same object, so two saves produce two
  transitions from one stale original — save the surviving record **once**.
- **Vocabulary lists are views** over the DISTINCT values actually recorded,
  per org. No seeding: a curated list goes stale, holding dead entries and
  missing new ones. The price is that two spellings are two rows and nothing
  normalises behind your back.

### Trap 21: run `flutter analyze` from the repo root

A run inside `apps/eiermann` analyses only the app — that is how nine findings
in a federfall package shipped unnoticed. Inside the packages themselves
`dart analyze` additionally crashes the analysis server, so **the root run is
their lint gate.**

## Versioning

`release-please` drives the version from Conventional Commits. **Never touch
`pubspec.yaml`'s version by hand.** Wire-breaking commits are `feat!:` — the
major version is the client/server wire contract, checked at runtime against
`/info`. That check fails **open**: an unreachable `/info` or a dev build never
blocks, and the message names which side must move.

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations. `cp`, `mv` and `rm`
may be aliased to `-i` on some systems, which hangs an agent forever waiting on
a y/n it cannot see.

```bash
cp -f source dest      # NOT: cp source dest
mv -f source dest      # NOT: mv source dest
rm -f file             # NOT: rm file
rm -rf directory       # NOT: rm -r directory
cp -rf source dest     # NOT: cp -r source dest
```

Also: `scp`/`ssh` with `-o BatchMode=yes`, `apt-get -y`,
`HOMEBREW_NO_AUTO_UPDATE=1` for `brew`.

## Session Completion

**When ending a work session**, complete the steps below.

1. **File issues for remaining work** — create issues for anything that needs
   follow-up
2. **Run quality gates** (if code changed) — `flutter analyze` from the root,
   `flutter test`, and the rule suite if the backend changed
3. **Update issue status** — close finished work, update in-progress items
4. **Commit** — directly on `main`, no feature branches
5. **Hand off** — provide context for the next session

**Pushing is deliberately NOT part of session completion in this repo.** Push
only when asked. This mirrors federfall's convention
(`federfall-commit-directly-on-main`) and reflects that **this repo has no git
remote at all yet** — a push would fail, and beads' generic "push to remote"
step does not apply. Do not reintroduce it without being asked.

**Never merge a pull request** unless explicitly asked — least of all a
release PR.
