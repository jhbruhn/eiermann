# Getting into eiermann

For a human joining the project. `CLAUDE.md` is the same repo for an agent — it
is denser and lists the traps; this file gets you to a running app.

## What this is

eiermann manages **Gelege** — city-pigeon clutches. A group has access to
buildings (**Spots**), each holding **Nester**, and each nest gets **Besuche**
on a rhythm. Eggs found on a visit are replaced with dummies, which is the
actual work; the app's job is to make sure somebody knows *which nest was last
checked when, and what was in it.*

It replaces a WhatsApp history. Three field problems drove the design, and they
are worth knowing before you read any code:

1. **The last state of a nest is unknowable** without asking whoever was there.
2. **Half clutches get lost** — a nest with one egg gets revisited too late and
   the second egg has hatched.
3. **Handover is painful.** Who has the key, which bell, which caretaker,
   what hours — all of it lives in one person's memory.

Everything in the data model earns its place against one of those. If a field
does not, question it.

The full concept is `docs/concept-digest.md`. Read it before designing
anything; it records decisions *and the alternatives rejected*, which is the
part you cannot reconstruct from the code.

`docs/feldhandbuch.md` is the other onboarding document — the one for the people
doing the work rather than writing it. Read section 4 even if you never go into
an attic: the Dohle-versus-Stadttaube sheet is the reason the protected-species
guard is shaped the way it is, and it is the one part of this system that no
line of code can enforce.

## Running it

You need Docker and Flutter (3.44.3 / Dart 3.12 — the same version as
federfall, deliberately in lockstep).

There are two ways to run it, and the difference matters.

**The whole app in one container** — what you want to just look at it:

```bash
cp -f .env.example .env          # port + the first coordinator
docker compose -f docker-compose.yml up -d --build
# → http://localhost:8091   (UI, API and Admin UI all on that one port)
```

The `-f` is not optional. Without it Compose also reads
`docker-compose.override.yml`, which builds the **lean backend target** — no
Flutter web build, so a hook or migration change rebuilds in seconds instead of
minutes. That image has an empty `pb_public`, so `/` answers 404 and it looks
like nothing is running. It is the right default for backend work and surprising
exactly once.

**Backend in Docker, app from Flutter** — what you want for UI work:

```bash
docker compose up -d --build     # lean backend on 8091, no UI
flutter pub get                  # from the repo ROOT — this is a pub workspace
cd apps/eiermann
flutter run -d chrome --dart-define-from-file=dart_defines/development.json
```

**That `--dart-define-from-file` is required.** On web the app uses
`Uri.base.origin` as its server unless a build-time `POCKETBASE_URL` says
otherwise — and under `flutter run` that origin is Flutter's own dev server on a
random port, not PocketBase. Without the flag the app looks for a backend at its
own address and finds none. `development.json` sets it to `http://localhost:8091`,
which is why the port is pinned to 8091 everywhere.

### The first user

A fresh instance has no way in until you make one, and the PocketBase Admin UI
account does **not** count: a superuser is a `_superusers` record with no org and
no role, so it cannot own a Spot, invite anybody, or appear in a visit history.

Set `EIERMANN_COORDINATOR_EMAIL` and `_PASSWORD` (plus an optional `_NAME`) in
`.env` and the app creates a coordinator on boot. `.env.example` ships the dev
defaults — **dev@eiermann.local / DevPass12345!** — which is a dev-only
convenience; never use them anywhere real.

It is idempotent and doubles as lockout recovery: an existing account is
reactivated and re-granted rather than duplicated, and the password is only ever
set on creation, so this cannot silently reset one the team has since changed.
Clear the variables once the team exists — credentials left in an environment are
how they end up in a backup somebody can read.

PocketBase's own admin UI is at `http://localhost:8091/_/`. Useful for looking
at data; **do not change the schema there.** Schema lives in migrations, and a
hand edit in the UI is a change no other machine will ever have.

## Checks before you push

```bash
flutter analyze                        # from the repo ROOT, always — see below
flutter test
./backend/pocketbase/tests/run.sh      # if you touched pb_hooks or pb_migrations
```

The rule suite boots a throwaway PocketBase, applies every migration, and makes
~100 assertions about who can read and write what. It takes about a minute and
it is the only thing standing between a plausible-looking access rule and a
public database.

**`flutter analyze` from the root, never from `apps/eiermann`.** A run inside
the app directory analyses only the app — that is how nine findings in a
federfall package shipped unnoticed.

## How the work is tracked

Issues live in **beads** (`bd`), not GitHub, and not in markdown TODO lists.

```bash
bd ready                  # what is available to work on now
bd show <id>              # one issue, with its dependencies
bd update <id> --claim    # take it
bd close <id> --reason="was tatsächlich passiert ist"
```

Issues are grouped into **phase epics**. The one that matters:
**Phase 04 (`eiermann-jbk`) is the cut.** After it the app replaces the
WhatsApp history and all three field problems above are solved. Everything from
Phase 05 on is addition, not completion — useful when deciding whether
something is worth doing now.

Two conventions that are not obvious:

- **Close with a real reason.** `bd close x --reason="done"` throws away the
  only durable record of *why* something ended up the way it did. The reason
  text is read far more often than the original description.
- **`bd remember`** is for knowledge that outlives an issue — a constraint
  discovered, a decision and its rejected alternative. Not MEMORY.md files.

## Committing

Conventional commits, **directly on `main`**, no feature branches.
`release-please` derives the version from the commit messages, so never edit
`pubspec.yaml`'s version by hand, and a wire-breaking change is `feat!:`.

**Pushing is not automatic here** — this repo has no git remote yet. Push when
asked.

Commit messages in this repo run long on purpose. The convention is that the
body explains *why*, including what was tried and rejected, because that is the
thing a diff cannot show. `git log` is the design record.

## The shared library

Anything that could serve both eiermann and federfall lives in **zugvogel**
(`../zugvogel`), consumed as a git dependency **pinned to a commit hash**. A
tag would be wrong: a tag can be re-pointed, pub caches by ref, and two
machines would then resolve the same declaration onto different code.

So a fix to shared code is three steps: change it in `../zugvogel`, push, bump
the hash in `apps/eiermann/pubspec.yaml`. **Do not fork a zugvogel file into
this repo** — a copy that drifts is worse than either version.

zugvogel deliberately contains no strings, no colours and no configuration, so
it cannot weld the two products together. All three are injected in
`apps/eiermann/lib/config/zugvogel_bindings.dart`. Source-sweep tests enforce
the boundaries, including over code that does not exist yet.

## Where the surprises are

`CLAUDE.md` has the full list. The three that will bite you first:

- **PocketBase timestamps are UTC and nothing converts them for you.** In CET,
  anything after 22:00 UTC renders as the previous day. Route every date
  through `formatLocalDate`; a sweep test enforces it.
- **Every PocketBase hook handler runs in its own JSVM context.** A helper
  declared at file level is not in scope inside the handler — the failure is a
  generic 400 at request time. `require()` inside the handler.
- **A PocketBase list is filtered, not refused.** An anonymous read of a fully
  private collection returns 200 with an empty array, so a test asserting
  `status >= 400` passes against a completely open database. Use the harness's
  `reads_nothing()`.
