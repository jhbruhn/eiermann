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

## Running it

You need Docker and Flutter (3.44.3 / Dart 3.12 — the same version as
federfall, deliberately in lockstep).

```bash
# 1. The backend. federfall's dev stack owns 8090, so pick another port.
EIERMANN_PORT=8091 docker compose up -d --build

# 2. The app, pointed at it.
flutter pub get                 # from the repo ROOT — this is a pub workspace
cd apps/eiermann && flutter run -d chrome
```

The dev stack seeds a coordinator: **dev@eiermann.local / DevPass12345!**. That
password is in a committed file, so this is a dev-only convenience — never set
those variables on anything real.

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
