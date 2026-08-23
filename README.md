# Eiermann

Eiermann is a field app for **Gelegemanagement** — the volunteer work of swapping real city-pigeon eggs for dummy ones (*Attrappen*), so a colony stops growing without a single bird being killed.
That work is cyclical, spread over dozens of buildings, and done by rotating people, which is why it fails on memory rather than on effort: on site nobody knows whether the eggs in the nest are last month's Attrappen or real ones, a *Halbgelege* — only one egg swapped because the second had not been laid yet — dies in a WhatsApp thread, and whoever walks the tour for the first time does not know how to get into the building at all.
Eiermann is the shared memory that replaces that thread.
Its own guiding line is *"Eiermann ist kein Formular, sondern ein Gedächtnis"* — not a form, a memory.

It is meant to be self-hosted.
The app is written in Flutter and runs on the web, Android and iOS; its interface is German.
The backend is [PocketBase](https://pocketbase.io) — a single Go binary with a SQLite database — and the whole thing runs as one Docker container.
Maps and address lookup use OpenStreetMap data.

The product concept it is built from is in [`docs/concept.html`](docs/concept.html), with an implementation-ready digest in [`docs/concept-digest.md`](docs/concept-digest.md).

## Installation

Eiermann is a server plus a client, and the server comes first — the app has no offline mode, so it needs an instance to talk to.
Running one is a single container behind a reverse proxy: `docker-compose.yml` is the production-shaped stack, and every setting it takes is documented next to it there and in [`.env.example`](.env.example).
Four are worth knowing before the first start:

- **The first user.** `EIERMANN_COORDINATOR_EMAIL` / `_PASSWORD` / `_NAME` create an app-level coordinator on boot. A PocketBase superuser is not one — it has no organisation and no role, so it cannot own a Spot or appear in a visit history. Setting them is idempotent and doubles as the lockout-recovery path.
- **SMTP.** Without a mail host the server reports `passwordReset: false` and the app hides the link rather than offering a button that silently does nothing.
- **The geocoder.** Address lookup runs through the server, never from the client. Left unconfigured it talks to the public Nominatim instance under a placeholder user agent — which works in development and stops the day it matters. Self-host Nominatim, or put a real contact address in `EIERMANN_USER_AGENT`.
- **The map source.** Prescribed at runtime rather than baked into the app, and all-or-nothing: mode, URL and the attribution the provider requires. The server derives its own Content-Security-Policy from the same URLs, so a tile source it names cannot be blocked by the policy it sent.

That same container serves the web app, so once it is up everyone can simply open its URL in a browser.
That is the least-effort way to use Eiermann and it needs nothing installed.
The mobile apps ask for your server's address on first launch.

There is no tagged release yet, so for now the way to get an instance is to build the image from this repository.
The pipeline is wired: a release publishes `ghcr.io/jhbruhn/eiermann` and, on the [releases page](https://github.com/jhbruhn/eiermann/releases), signed Android APKs — a universal build plus smaller per-ABI splits (`arm64-v8a` for anything recent, `armeabi-v7a` for older phones).
If you take updates through an unattended updater such as [Obtainium](https://github.com/ImranR98/Obtainium), keep its filter on one of those variants: switching between them reads as a downgrade and the install fails.
There is no iOS download; that one you build and sign yourself.

The app checks its own major version against the server's on sign-in and says which of the two has to move.
It fails open — an unreachable server or a development build never blocks.

## Repository layout

This is a [Dart pub workspace](https://dart.dev/tools/pub/workspaces) monorepo:

```
eiermann/
├─ Dockerfile              # single-container image (PocketBase + Flutter web app)
├─ docker-compose.yml      # the stack (+ .override.yml for dev, .oidc.yml for OAuth2)
├─ apps/
│  └─ eiermann/            # the Flutter app
├─ packages/
│  ├─ eiermann_models/     # domain models + PocketBase record mappers
│  └─ eiermann_data/       # repositories over the PocketBase API
├─ backend/
│  └─ pocketbase/          # migrations, hooks, Typst report templates, rule tests
└─ docs/                   # the concept and its digest
```

The generic half of all of this — the repository base, the PocketBase client, the shared widgets, the hook libraries, the report chrome — lives in [zugvogel](https://github.com/jhbruhn/zugvogel), shared with [federfall](https://github.com/jhbruhn/federfall) and pinned by commit hash.
What stays here is what knows about eggs.

## Running it locally

From the repository root:

```bash
docker compose up -d --build
```

The development override applies automatically and builds the **lean** backend on `http://localhost:8091` — no Flutter web build, so a change to a hook or a migration rebuilds in seconds.
It therefore serves no UI; the app runs on the host with hot reload, pointed at that same backend:

```bash
cd apps/eiermann
flutter run -d chrome \
  --target lib/main_development.dart \
  --dart-define-from-file=dart_defines/development.json
```

For the whole app in one container — a demo, or checking what a release actually ships — skip the override:

```bash
docker compose -f docker-compose.yml up -d --build
```

`docker-compose.oidc.yml` adds a throwaway mock OpenID provider on top of that, so the sign-in-through-an-identity-provider path can be walked end to end without a real one.

The checks, all from the root:

```bash
flutter analyze                      # the whole workspace — a run inside apps/ misses the packages
flutter test
backend/pocketbase/tests/run.sh      # boots a throwaway PocketBase, applies the migrations,
                                     # asserts the access rules and the hooks
```

The rule suite is the one to run before touching anything about access.
It asserts the security model against a live instance — including the privilege escalations that access rules alone cannot prevent, which is what the hooks are for.

## Usage

Eiermann is organised around four sections: **Dashboard**, **Karte**, **Liste** and **Touren**.
On a phone they are a bottom bar; on a tablet or a desktop browser they become a side rail.
The account button holds the rest: your profile, the figures, and — for the coordination — the management hub.

The dashboard is how much work is waiting, as four numbers: overdue, due today, due soon, and running Erkundungen.
Each taps through to the list behind it, and a number at zero is plainly a number and not a promise.
Above all four sit the open **Halbgelege**, because out of a half clutch a chick hatches in days — it is the one deadline here that a week's delay ruins, and counting it among the others would put a four-day window next to a four-week one.

### The Spot dossier

A **Spot** is one building, one address, and its dossier is the screen the work happens on.
The order of the page is the design: who and where, then **how you get in**, then whom to ring.
The access note comes before the contacts and before everything else because it is the answer to the painful handover — not a participant list, but what the next person needs to enter the building at all.
Contacts are structured by role (Eigentümer, Verwaltung, Hausmeister, Mieter), one of them primary.

Above the nests stands the single most useful line of the app: *"Einpacken: 3 Attrappen"* — how many dummy eggs to put in the car, derived from what is lying in the nests right now.

A Spot moves through phases rather than being deleted.
**Erkundung** (prospecting) is its own phase with the funnel stage it has reached — untouched, tenant spoken to, owner spoken to, permitted, refused — and that stage stays recorded after the transition, because how permission was won is part of the dossier.
An active Spot can be **paused** with a reason and an optional date it resumes by itself (scaffolding, winter), or **closed** with one: netted, permission withdrawn, building gone, no pigeons left.
Deleting is the coordination's, and rarely what anybody wants: closing keeps the whole history.

### Bereiche and the photo map

A **Bereich** is a named part of a building — "Dachboden Nord", "Lichtschacht" — and it carries one overview photo.
The nests are pins on that photo: tap the photo to add a nest where you tapped, drag a pin to correct it, tap a pin to open the nest.
Pins are stored relative to the image, so a new photo or a different screen width does not scatter them.

When the photo is replaced, the previous one is kept alongside it and every pin is marked for review, so old and new can be compared and each nest confirmed or moved before the old photo goes.
A nest that has no pin yet is listed under the photo rather than hidden — an incomplete map that looks complete is the failure mode here.

### Protected species

City pigeons are feral domestic animals and not specially protected.
Jackdaws, wood pigeons, swifts and kestrels nesting in the same attics **are**, and interfering with their clutches is a criminal offence under §44 BNatSchG.
This is the one real risk the app could amplify, because it makes clutch swapping faster and more routine — so it is handled by refusal, not by a warning.

Every egg mutation on a nest marked `protected` is rejected server-side, inside the visit transaction and on every other path.
On the photo map such a nest carries its own symbol and offers no swap action at all.
Anybody may mark a nest as protected — seeing a protected species and saying so must never be gated — but only the coordination can take it back out, because that re-enables egg removal.
The app does not identify species: **unknown** is its own state and never a silent assumption of "city pigeon", and it stays on the dossier as an open question until somebody decides it.

### Recording a Besuch

A **Besuch** is one visit to one building on one occasion, and it is written as a single transaction at the end.
You work through the nests of the Spot, and per nest say what happened: swapped, **Halbgelege**, empty, untouched, not reachable, gone, or protected.
The egg slots show what is in the nest and since when, so the *Ist-Gelege* is a thing you correct rather than a form you fill.
Photos and a note can hang off a nest, off the visit, or off a finding.

A visit where nobody could get in is recorded too, with a reason — nobody there, no key, access blocked, no time, building works.
That is a fact about the building, not a failure to use the app, and it deliberately does not enter the rhythm: a locked door is not the observation of an empty nest.

Everything is held in memory until the last button.
That is the mitigation for having no offline mode, and a deliberate trade: in a cellar with no reception exactly one call fails, at a named point, with a retry that is safe to press three times because the visit carries one idempotency key.
The form survives losing reception; it does not survive the app being killed, and that is a stated limit.

### The Rhythmus

Every nest becomes due again on its own cadence.
Three consecutive empty checks stretch it a rung — 7 days, then 14, then 28 — and a single egg, chick or dead pigeon puts it straight back to the base.
A Spot is due when its earliest nest is, and a Spot with no nests is still due after the base period: empty does not mean done.

A **Halbgelege** does not stretch anything; it opens a **Nachkontrolle** a few days out, which wins over every other date because it is earlier, and closes only when a later check on that same nest completes the swap.

Next to every due date stands the sentence that explains it — *"4× nichts gefunden — Rhythmus jetzt 14 Tage"*, or which nest's Nachkontrolle is pulling the date forward.
A date you are told to trust but never shown is a date people override.
The numbers behind it belong to the organisation, not to a release: the coordination edits them in the management hub, and every member can read them.

### Funde

Anything found that is not a clutch gets recorded as a **Fund**: a dead bird, a chick, another species, or a change to the building itself.
Species names are free text, and the picker offers what the group has actually written before — a vocabulary that grows from use, with nothing to seed and nothing dead in it.
A structural change offers closing the Spot as the next step, since that is usually what it means.

### Touren

A **Tour** is a named, ordered route of Spots, and a run is one walk along it.
The route somebody planned last month and the round they are walking today are allowed to differ: adding a stop and skipping one are buttons of equal weight, not error paths, because an app that treats every deviation as a mistake gets closed and the round gets written in WhatsApp again.

A run holds nothing on the device — its progress is the visits themselves — so it can be picked up on another phone, after a reboot, or an hour later, and the dashboard offers to continue it.
There is also the improvised version: overdue buildings near you, nearest first, for an afternoon that was not planned.

### Zahlen und Berichte

The figures for a period — visits, nests checked, eggs removed, dummies placed, how the checks came out, findings — arrive from the server already computed, which is the same aggregation the printed report runs.
Somebody will put the screen and the PDF side by side in front of an authority, and two implementations would disagree the first time either was touched.
Rates are shares of a completed denominator and read as nothing rather than 0 % while nothing has completed.

The same period exports three ways, off one route over one row set: the **Behördenbericht** (every visit grouped by address, including the ones where nobody was there — for a permission and its renewal), the **Förderer-Zusammenfassung** (the same period as figures, trend and distribution) and the same table as CSV for a spreadsheet.
The PDFs are rendered server-side with [Typst](https://typst.app).

## Roles

Two roles, not four.
This is a small team where everybody does the field work, so a read-only role would be inventing a person who does not exist.

**Mitglied** (member) is everyone doing the rounds: record visits, swap eggs, add areas and nests, mark a nest protected, write findings, run tours, read the figures and produce a report.
Everything inside the organisation is readable by every active member — that is the entire point of a Gedächtnis.

**Koordination** (coordinator) additionally decides what is hard to undo: delete a Spot or a Bereich rather than closing it, take a nest back out of `protected`, change the rhythm numbers every due date in the app comes out of, manage the team and read the audit log.
The first coordinator comes from the environment on first start.

**Gast** (guest) exists only for self-registration through an identity provider: a guest is authenticated and refused by every access rule until a coordinator grants them a real role.
It is a wall, not a low tier.

Nobody is ever deleted from the team.
A departed member's name still has to appear on every visit they recorded, so access ends with `is_active = false` — which takes effect on a live session, not at the next sign-in — and the row stays in the roster, because "who was Meike?" is exactly the question an old visit prompts months later.

A handful of acts leave a trace in the audit log rather than only in the record they changed: releasing a protected nest, closing a building, granting the coordination, stretching an interval.
Those entries store the text as it read when the act happened, so a building that has since been renamed or deleted still says what it was called.
The log is the coordination's to read, and nothing in the app can write to it.

## Vibe Code Warning

For reasons of fairness and possibly also as a warning, be aware that almost all of the code in this project has been written using LLMs, specifically Claude Code.

That does not mean that the code is untested, bad or dysfunctional.
The backend access rules and hooks have a test suite that runs against a live instance, and the app has widget and unit tests.

This project wouldn't have happened in its current form without LLMs.
So, while LLMs are still being heavily oversold and the circular economy of the big AI companies is not exactly a healthy market IMO, they do still offer _some_ benefits.

## License

Eiermann is licensed under the [GNU AGPL-3.0](LICENSE).
This is a network-copyleft license: if you run a modified version as a service, you have to share your changes.
