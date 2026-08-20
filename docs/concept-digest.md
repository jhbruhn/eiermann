# Eiermann — Implementation-Ready Concept Digest

Source: `docs/concept.html` (German, dated 20.08.2026) plus the beads issue tracker
(`bd`) as of 2026-08-21. This digest is in English; German domain terms are kept
verbatim because they are the vocabulary the users and the code will speak.

**Glossary of German domain terms used throughout (first-use glosses):**

| Term | Gloss |
|---|---|
| **Gelege** | a clutch — the set of eggs currently lying in one nest |
| **Ist-Gelege** | the *live* clutch — what is physically in the nest right now |
| **Halbgelege** | half clutch — only one egg could be swapped because the second had not been laid yet; someone must return within days |
| **Nest** | nest (plural *Nester*) |
| **Besuch** | a visit to one Spot on one occasion (plural *Besuche*) |
| **Spot** | a building / address (the concept uses the English loanword as the German term) |
| **Bereich** | area — a named part of a building ("Dachboden Nord", "Lichtschacht") that carries one overview photo with the nest pins |
| **Attrappe** | dummy egg (plural *Attrappen*) |
| **Nachkontrolle** | follow-up check, the scheduled return after a Halbgelege |
| **Erkundung** | prospecting — the funnel of getting permission to enter a building |
| **Koordination** | the coordinator role |
| **Fund** | finding (plural *Funde*) — dead bird, chick, protected species, structural change |
| **Rhythmus** | the per-Nest cadence at which a nest becomes due again |
| **Übergabe** | handover between volunteers |

Stack: PocketBase + Flutter. Platforms: Android, Web, iOS. UI language: German
primary, English secondary. Template/predecessor project: `fluttermann` /
`federfall`. Shared library: `zugvogel`.

---

## 1. What the app is, in three sentences

Volunteers swap real pigeon eggs for **Attrappen** in city-pigeon nests so the
population does not grow without any bird being killed; the work is cyclical,
spread across many buildings, and done by rotating people. Today that work fails
on memory, not on effort: nobody on site knows what the nest looked like last
time, a **Halbgelege** note dies in a WhatsApp thread, and a first-timer on the
tour does not know how to even get into the building. Eiermann replaces the
WhatsApp thread with a shared memory: tap a **Spot** and within five seconds you
see how many **Attrappen** to pack, which **Nest** is urgent, which one you must
not touch, and whom to call to get in.

The concept's own guiding line: **"Eiermann ist kein Formular, sondern ein
Gedächtnis"** — Eiermann is not a form, it is a memory. Anything that does not
serve that sentence is ballast. The stated acceptance measure:

> "Ein Mensch, der noch nie an einem Spot war, tippt ihn an und weiß innerhalb
> von fünf Sekunden: wie viele Attrappen einzupacken sind, welches Nest dringend
> ist, welches man nicht berühren darf, und wen man anrufen muss, um überhaupt
> reinzukommen."

---

## 2. The domain model

Twelve domain collections plus infrastructure and five views. Concrete enough to
write PocketBase migrations from.

### 2.0 The two structural rules that shape every table

1. **Ist-Zustand vs. Ereignis** (live state vs. event). What is *now* in the nest
   lives in `nest_eggs` — mutable, small, one row per egg, with a `since` date per
   slot so that "1 Attrappe since 12 days" is a field query and not an
   aggregation. What somebody *did* lives in `nest_checks` — immutable, stored as
   **scalars**, so every report is plain SQL.
2. **No JSON in the domain.** Not one JSON field in the domain model. Exactly one
   JSON field exists in the whole database — `organisations.settings` — and it has
   exactly one reader, `lib_org.js`. Rationale (both paid for in federfall):
   `record.get("settings")` hands JS a `types.JSONRaw` byte array, so every
   property access is `undefined` and code falls *silently* into its default
   (federfall-jumi); and a computed view column is demoted to type `json`, so
   `getString()` returns `"Hohltaube"` *with* quotes (federfall-dk0c). Therefore
   `real_before`, `removed_real`, `added_dummy` and friends are `number`.

### 2.1 The centre of the model

- **`spots` is the centre of the product.** Everything hangs off it: areas,
  nests, contacts, visits, findings, follow-ups, tour_spots. The Spot-Detail
  screen is explicitly "das Produkt"; the map is only the entry point.
- **`nests` is the centre of the mechanics.** The **Rhythmus** ladder runs per
  nest; `nest_eggs` and `nest_checks` hang off it; the protected-species guard
  keys on it. `nests.spot` is deliberately **denormalised** so map queries and
  scope rules do not need two hops.
- **`visits` is the centre of writing.** One visit is one transaction through one
  endpoint; `nest_checks`, `nest_eggs` mutations, `findings` and `follow_ups` all
  come into existence through it.
- Every domain collection carries an **`org`** relation (multi-tenant built, one
  org seeded).

### 2.2 Places

**`spots`** — one building / one address.

| Field | Notes |
|---|---|
| `org` | relation, on every collection |
| `name` | |
| `street`, `postal_code`, `city` | |
| `geo` | geoPoint. `{0,0}` must be treated as null (trap 08) |
| `geo_confirmed` | bool — was the pin manually confirmed/corrected |
| `phase` | `prospect` / `active` / `paused` / `closed` |
| `prospect_stage` | `unberührt` / `Mieter gesprochen` / `Eigentümer gesprochen` / `erlaubt` / `abgelehnt`. **Stays set after the transition** — the Erkundung history is part of the dossier |
| `paused_until` | optional auto-resume date (scaffolding, winter) |
| `pause_reason` | |
| `closed_reason` | one of: vernetzt (netted), Erlaubnis entzogen (permission withdrawn), Gebäude weg (building gone), keine Tauben (no pigeons) |
| `closed_at` | set server-side |
| `access_note` | the "how do I get in" text |
| `note` | |
| `facade_photo` | |
| `next_due_at` | **derived but stored**, so the map colours in one query |

**`spot_contacts`** — structured contact persons.

| Field | Notes |
|---|---|
| `org`, `spot` | |
| `role` | Eigentümer / Verwaltung / Hausmeister / Mieter / sonstige |
| `name`, `phone`, `email`, `note` | |
| `is_primary` | bool |

PII: excluded from audit content fields. **Deliberately no scrub cron** (unlike
federfall's `finders`): a Hausmeister contact is needed as long as the Spot
exists — it expires with the Spot.

**`areas`** — a **Bereich**; carries the overview photo and therefore the pins.

| Field | Notes |
|---|---|
| `org`, `spot` | |
| `name` | e.g. "Dachboden Nord" |
| `photo` | the overview photo |
| `previous_photo` | holds **exactly one** generation, and only while `pins_need_review` is running, so old and new can be seen side by side; deleted afterwards |
| `photo_taken_at` | |
| `pins_need_review` | bool — set on photo replacement, cleared when every pin has been confirmed or moved |
| `sort_index` | |
| `note` | |

Small Spots have exactly one Bereich.

### 2.3 Nests and eggs

**`nests`**

| Field | Notes |
|---|---|
| `org`, `spot`, `area` | `spot` denormalised on purpose |
| `label` | "N3" |
| `position_hint` | free text — "Balken links"; what a pin cannot say |
| `pin_x`, `pin_y` | **normalised 0…1, never pixels** — otherwise every new photo and every screen width destroys the map |
| `photo` | the nest's own photo |
| `species` | `feral_pigeon` / `protected` / `unknown` |
| `species_label` | free-text species name |
| `status` | `active` / `gone` |
| `interval_days` | current ladder rung — written only by `lib_rhythm.js` |
| `empty_streak` | consecutive empty checks — written only by `lib_rhythm.js` |
| `next_due_at` | derived, stored — written only by `lib_rhythm.js` |

**`nest_eggs`** — **the Ist-Gelege.** One row per egg currently in the nest.

| Field | Notes |
|---|---|
| `org`, `nest` | |
| `slot_index` | the slot in the egg row |
| `kind` | `real` / `dummy` |
| `since` | date this egg has been in the nest — drives "1 Kunstei seit 12 Tagen" |
| `source_check` | relation to the `nest_checks` row that produced it |

Rows are **deleted** when the egg leaves the nest. **Only the visit endpoint
writes here — for clients the collection is not writable at all.**

**`nest_checks`** — **the event, immutable.**

| Field | Notes |
|---|---|
| `org`, `visit`, `nest` | |
| `state` | `swapped` / `partial` / `empty` / `untouched` / `not_reachable` / `gone` / `protected` |
| `real_before`, `dummy_before` | number |
| `real_after`, `dummy_after` | number |
| `removed_real`, `added_dummy` | number |
| `note`, `photo`, `author` | |

`partial` **is** the Halbgelege: after the swap a real egg is still in the nest.
The invariant `*_after = *_before − removed + added` is enforced **by the hook,
not by the UI**.

### 2.4 Visits, findings, tours

**`visits`**

| Field | Notes |
|---|---|
| `org`, `spot`, `tour_run` | `tour_run` optional |
| `visited_at` | |
| `outcome` | `checked` / `skipped` |
| `skip_reason` | niemand da / kein Schlüssel / Zugang versperrt / keine Zeit / Bauarbeiten / sonstiges |
| `skip_note`, `note`, `author` | |

**A skipped Besuch does not enter the Rhythmus at all** — it documents a
non-event, not the observation of an empty nest.

**`visit_photos`** — `org`, `visit`, `image`, `caption`. Photos that belong to no
nest: the door, the new lock, the scaffolding.

**`findings`** — the **Funde**.

| Field | Notes |
|---|---|
| `org`, `visit`, `spot`, `nest` | `nest` optional |
| `kind` | `dead_bird` / `chick` / `other_species` / `site_change` |
| `count` | number |
| `species_label` | **free text**, feeds the `species_labels` view — vocabulary that grows from use (federfall's `animal_species` pattern: nothing to seed, nothing dead in the picker) |
| `note`, `photo` | |

A `site_change` finding offers "Spot schließen" as a follow-up action.

**`follow_ups`** — the **Nachkontrolle**.

| Field | Notes |
|---|---|
| `org`, `spot`, `nest` | |
| `due_at` | **stored, not derived** — a plan is a fact and must not shift retroactively because somebody later changed an interval in the org settings (federfall's `next_due_at` lesson from vaccinations) |
| `reason` | `half_clutch` / `manual` |
| `note` | |
| `created_from_check` | relation to the `partial` check |
| `resolved_at`, `resolved_by_check` | |

**`tours`** — `org`, `name`, `note`, `is_active`, `sort_index`. The template
("Tour 1").

**`tour_spots`** — `org`, `tour`, `spot`, `sort_index`. The ordered route.

**`tour_runs`** — `org`, `tour`, `started_by`, `started_at`, `finished_at`,
`note`. `tour` is **optional** — a run without a template is the improvised
round. A run without `finished_at` is open and is offered on the dashboard as
"Tour 1 fortsetzen".

### 2.5 Infrastructure collections

| Collection | Content |
|---|---|
| `organisations` | `name`, contact, `settings` (JSON). Carries the Rhythmus numbers, the Nachkontrolle window and report metadata — changeable without a release. **The only JSON field; only reader is `lib_org.js`.** |
| `users` | **Extends the built-in auth collection** (never recreate it, or the built-in email/password wiring is lost) with `role` (member/coordinator), `org`, `is_active`, `invited_by`, `phone` |
| `audit_events` | append-only, tamper-locked, readable only by Koordination. Stores **label snapshots**, never resolvable ids |
| `geocode_cache` | cache in front of the Nominatim proxy, with purge cron |
| `idempotency_keys` | makes replaying a visit write safe — the keystone of the online-only decision |

### 2.6 Views — every list reads one query, not four

| View | Content |
|---|---|
| `spot_overview` | Spot + area count + nest count + Gelege summary + `next_due_at` + open Nachkontrollen + urgency rank. **The map and the Spot list read only this.** |
| `nest_state` | Nest + Ist-Gelege (real/dummy), oldest `since`, days in state, `next_due_at`. Feeds the nest list in the Spot detail. |
| `visit_rows` | The report table: address, date, outcome, eggs removed, dummies placed, findings. **Defined once**; both report framings and the CSV export read it so they cannot drift apart. |
| `species_labels` | DISTINCT over species labels actually recorded, per org |
| `due_counts` | dashboard counters in one query |

### 2.7 The Rhythmus rules (write them exactly like this)

`lib_rhythm.js` is **the only place** that computes `empty_streak`,
`interval_days`, `nest.next_due_at` and `spot.next_due_at`. Every writer calls
it; nobody computes their own.

- A completed check with `state = empty` increments `empty_streak` by one.
- Every egg, every chick, every dead pigeon, every inhabited nest sets
  `empty_streak = 0` and resets `interval_days` to the base.
- `interval_days` is the ladder rung for the current streak, capped.
- `nest.next_due_at = date of the last completed check + interval_days`.
- `state = partial` creates a `follow_ups` row with
  `due_at = today + half_clutch_return_days`. It is resolved when a later check
  **on this nest** completes the swap — not by time passing and not by a skipped
  visit.
- `spot.next_due_at = min(all active nests, all open follow-ups)`. **A Spot with
  no nests is due after the base period — empty does not mean done.**
- A `paused` Spot drops out of all due lists; `paused_until` makes it restart by
  itself via cron.
- The ladder as drawn: base 7 days (`empty_streak` 0–2) → 14 days (3–5) → 28 days
  (cap). Reset arc: one egg, one chick, one dead pigeon → straight back to base.
- An open Halbgelege follow-up is **not a ladder state** but a second date that
  enters the same minimum — and because it is earlier, it wins.

**Numbers live in `organisations.settings`:**

| Key | Default | Meaning |
|---|---|---|
| `base_interval_days` | 7 | base rhythm of an active nest |
| `empty_checks_per_step` | 3 | how many consecutive empty checks advance one rung |
| `interval_steps` | `[7, 14, 28]` | the ladder; last value is the cap |
| `half_clutch_return_days` | 4 | window for the Nachkontrolle after a Halbgelege |
| `pause_auto_resume` | `true` | whether `paused_until` reactivates automatically |

Read **exclusively** through `lib_org.js`. A second `getString()` + `JSON.parse`
silently disabled federfall's org-configurable windows.

**The app must be able to explain the date.** Next to every due date stands a
sentence — "4× nichts gefunden — Rhythmus auf 14 Tage gestreckt" or
"Nachkontrolle Halbgelege, Nest 3" — built **in the client** from `empty_streak`,
`interval_days` and the follow-up reason. Not delivered by the server: the server
does not get to decide which language the reader speaks.

### 2.8 The visit transaction

`POST /api/eiermann/visit` takes the whole Besuch as one body and writes it in
one transaction (after federfall's `intake.pb.js` pattern), then calls
`lib_rhythm.js`. Rejected alternative: seven individual REST writes — if the
connection breaks after the second nest, the database holds a visit where two
nests were not checked, **and that is indistinguishable from "two nests
deliberately not touched."**

The **Idempotency-Key** is the point: replaying with the same key returns the
stored response, not a second visit. This is also the answer to "no offline": the
visit form collects everything in memory and writes only on completion, so in a
cellar without reception exactly *one* call fails, at a named place, with a
"Erneut senden" button that can be pressed three times safely. The form survives
loss of reception — but not the app being killed.

### 2.9 The protected-species guard (`protected_guard.pb.js`)

City pigeons are feral domestic animals and not specially protected. Jackdaws
(Dohlen), wood pigeons, swifts and kestrels sitting in the same attics **are** —
any interference with their clutches is prohibited under §44 BNatSchG. This
confusion is the largest real risk the app can *amplify*, because it makes clutch
swapping faster and more routine.

- Server-side rejection, **not a warning**: every egg mutation on a nest with
  `species = protected` is rejected — inside the transactional visit endpoint
  *and* on every direct path — with an error message naming the species and the
  reason.
- A nest can be set from `unknown` to `protected` by anyone; **the way back is
  reserved for Koordination**.
- On the photo map a protected nest is not merely coloured differently: it carries
  its own symbol and is **not tappable for "Eier tauschen"**.
- The app does **not** identify species. `unknown` is its own state and never a
  silent assumption of "city pigeon"; an undetermined nest is carried in the Spot
  detail as an open question until someone decides.

### 2.10 Access rules

The access rules are the security boundary, not the UI. Simpler than federfall
because **private-by-default does not apply**: everything inside the org is
readable by every active member — that is the whole point of a Gedächtnis.

Coordinator-only: delete spots and areas, override rhythms, manage the team, read
the audit log, export, reset a nest from `protected`. `nest_eggs` is not writable
by clients at all. Every rule that copies the auth predicate ends with
`&& @request.auth.is_active = true`; the rule test suite sweeps for this and fails
on an omission.

### 2.11 Hooks

| File | Responsibility |
|---|---|
| `lib_rhythm.js` | **the only derivation** — `empty_streak`, `interval_days`, `nest.next_due_at`, `spot.next_due_at` |
| `visit.pb.js` | `POST /api/eiermann/visit` — whole visit, one transaction, idempotency-keyed; enforces the Gelege invariant, then calls `lib_rhythm.js` |
| `protected_guard.pb.js` | rejects every egg mutation on a protected nest — the security-critical hook |
| `follow_ups.pb.js` | creates and resolves the Halbgelege Nachkontrolle |
| `area_photo.pb.js` | photo replacement: old → `previous_photo`, set `pins_need_review`, clean up on confirmation |
| `nest_pins.pb.js` | clamps `pin_x`/`pin_y` to 0…1 and rejects a pin on an area without a photo |
| `spot_phase.pb.js` | phase transitions: closing reason mandatory, `closed_at` server-side, `paused_until` plausibility, resume via `cronAdd` |
| `report.pb.js` | `GET /api/eiermann/reports/period` → Typst PDF; `?format=summary`, `?format=csv`. One route, because isolated handlers could not share the collection code |
| `stats.pb.js` | `GET /api/eiermann/stats` — the whole statistics screen in one response |
| `lib_stats.js` | owns the period (`?year=`, `?month=`, `?tzOffsetMinutes=`), the `visit_rows` read and every aggregation |
| shared (from zugvogel base image, `zv_*` namespace) | `lib_org.js`, `lib_org_scope.js`, `org_scope.pb.js`, `lib_audit.js`, `audit_*.pb.js`, `lib_authorship.js`, `authorship.pb.js`, `lib_time.js`, `lib_geocode.js`, `geocode.pb.js`, `info.pb.js`, `web_headers.pb.js`, `rate_limits.pb.js`, `settings.pb.js`, `bootstrap_coordinator.pb.js`, `oauth2_provisioning.pb.js` |

---

## 3. The three named field problems (quoted)

The concept states these as the touchstone for every design decision
("sie sind der Prüfstein für jede Designentscheidung hier"):

1. > **"Niemand weiß mehr, wie es letztes Mal aussah.** Vor Ort ist unklar, ob
   > die Eier im Nest die eigenen Attrappen sind oder echt, und seit wann sie da
   > liegen. Das Wissen steckt in einem Kopf oder einem WhatsApp-Verlauf."

   *(Nobody knows any more what it looked like last time. On site it is unclear
   whether the eggs in the nest are our own Attrappen or real, and since when
   they have been lying there. The knowledge sits in one person's head or in a
   WhatsApp thread.)*

2. > **"Halbgelege gehen verloren.** Wenn nur ein Ei getauscht werden konnte,
   > weil das zweite noch nicht gelegt war, muss jemand in wenigen Tagen
   > wiederkommen. Diese Notiz überlebt den Alltag nicht — und dann schlüpft das
   > zweite Ei."

   *(Halbgelege get lost. If only one egg could be swapped because the second had
   not been laid yet, someone must come back within a few days. That note does
   not survive everyday life — and then the second egg hatches.)*

3. > **"Die Übergabe ist schmerzhaft.** Wer die Tour zum ersten Mal macht, kennt
   > die Häuser nicht: nicht den Zugang, nicht die Ansprechpartner, nicht die
   > Nester, die man nicht anfassen darf."

   *(The handover is painful. Whoever does the tour for the first time does not
   know the buildings: not the access, not the contact persons, not the nests you
   must not touch.)*

---

## 4. The phase plan

Nine phases (00…08). The order is real: every phase needs the previous one. Each
phase ends usable. Tracked in beads, not in markdown lists.

| Phase | Epic | Delivers | End state |
|---|---|---|---|
| **00** | `eiermann-d2a` (P0, 18/21 done) | Create `zugvogel` and fill it with what is already stable and free of federfall references. Switch federfall onto the library. Build the base image. | Proof: federfall's existing test suite is green **without modification** |
| **01** | `eiermann-h7q` (P0, 0/20) | Repo, pub workspace, `analysis_options`, CI, Docker, release-please. PocketBase with organisation, users, roles, access-rule baseline, bootstrap coordinator. Server setup, login, version check, startup gate, l10n de/en, theme. | You can sign in and see an empty app |
| **02** | `eiermann-upa` (P0, 0/13) | `spots`, geocode proxy with cache, map with runtime configuration, pin correction, phases and Erkundung stages, `spot_contacts`, access note, `spot_overview` view, Spot list with keyset pagination | Buildings are recorded, findable and backed by contacts — **half of the Übergabe pain is solved** |
| **03** | `eiermann-bmg` (P0, 0/12) | `areas` with photo upload and crop, normalised pins, Bereich editor, `nests` with species and position hint, the photo-replacement review pass, `protected_guard.pb.js` | The visual nest map stands. **The protected-species guard exists before the first egg, not after** |
| **04** | `eiermann-jbk` (P0, 0/15) | `nest_eggs`, `nest_checks`, `visits`, the transactional visit endpoint with idempotency, Nest-Sheet with egg slots, skipped-with-reason, `lib_rhythm.js`, `follow_ups`, the dashboard | ⭐ **THE CUT** |
| **05** | `eiermann-avq` (P1, 0/6) | Templates, ordered spot lists, runs with progress, deviation, resumption after app restart, plus the improvised "overdue near me" mode | "Tour 1 starten" works literally |
| **06** | `eiermann-3is` (P1, 0/5) | Dead pigeons, chicks, protected species, structural changes. `species_labels` view. The path from a structural change to closing a Spot | |
| **07** | `eiermann-fi2` (P1, 0/8) | `visit_rows` view, `lib_stats.js`, `/stats`, statistics screen, Typst reports in both framings plus CSV, period selection with previous-year comparison | The proof that keeps a permission or a funding alive |
| **08** | `eiermann-uwd` (P2, 0/9) | Team invites, org-settings UI for the Rhythmus numbers, audit log, pause-resume cron, OIDC switchable, web build and CSP, Android signing, iOS signing and store submission | iOS is deliberately here: it is distribution, not product |

Plus a cross-cutting epic that is not a phase: **`eiermann-934` "Querschnitt —
Leitplanken und Testharness"** (P1, 0/10) — the twenty transplanted traps made
enforceable as sweep tests, registries, the live-PocketBase rule suite and the
separate cron harness. Depends on Phase 00; cross-cuts every phase.

### ⭐ Phase 04 is the cut

> "Der Schnitt: ab hier ersetzt die App den WhatsApp-Verlauf. Alle drei benannten
> Probleme sind gelöst."

After Phase 04 (`eiermann-jbk`) the app is useful in the field even if nothing
after it ever exists. All three named field problems are solved and the app
replaces the WhatsApp thread. **Everything from Phase 05 onward is addition.**
This is also recorded as a beads memory (`phase-04-ist-der-schnitt`).

The concept's own "next actionable" statement: Phase 00 and 01 — the zugvogel
extraction and Eiermann's foundation. Both are mechanical enough to start
immediately and both are prerequisites for everything else.

---

## 5. Phase 01 in detail — `eiermann-h7q`

**Epic:** "Phase 01 — Fundament: repo, CI, PocketBase-Basis, Anmeldung" (P0,
label `infra`, 0/20 complete). Depends on `eiermann-d2a` (Phase 00). Blocks
`eiermann-upa` (Phase 02).

Epic scope: workspace, quality gates, container build, release-please, the
org/users migration, access-rule baseline, server setup + login + version
compatibility. **Ends with: you can sign in and see an empty app.**

All 20 children, in numeric order:

| Id | Title | What it requires |
|---|---|---|
| **h7q.1** | eiermann-Repo aufsetzen: Pub-Workspace, analysis_options, gitignore, LICENSE, README | P0, `infra`. `very_good_analysis`, strict. The lints that bite: 80-char lines, alphabetically sorted imports, Dart 3 null-aware elements instead of `if (x != null)`, no redundant default args, no positional bool params, typed non-obvious static consts. |
| **h7q.2** | CLAUDE.md und AGENTS.md mit den übernommenen Regeln | P0, `docs`+`infra`. Carry the twenty transplanted traps forward as project instructions, not as folklore. Commit directly on `main`; push only when asked. *(Note: this repo has since folded AGENTS.md into CLAUDE.md.)* |
| **h7q.3** | Flutter-App-Skelett: Flavors, dart_defines, bootstrap, app/view | P0, `flutter`+`infra`. `development` / `staging` / `production` dart_defines. `POCKETBASE_URL`, `MAP_TILE_URL`, `MAP_ATTRIBUTION` are compile-time constants and need a **rebuild, not a hot reload** — a stale build silently falls back to defaults. |
| **h7q.4** | Pakete `eiermann_models` und `eiermann_data` mit build_runner | P0, `flutter`+`infra`. freezed domain models with `fromRecord` mappers; enums carry a `wire` value so a Dart rename never breaks mapping. Codegen is required, not optional. |
| **h7q.5** | l10n: `l10n.yaml`, `app_de.arb` als Primärsprache, `app_en.arb` | P0, `flutter`+`infra`+`l10n`. German is the primary UI language. Config is `l10n.yaml` — **CLI args are ignored**. Regenerate with `flutter gen-l10n` after every ARB edit. |
| **h7q.6** | Theme und Palette, gebündelte Fonts, Fallback-Pinning-Test | **P1**, `flutter`+`infra`. Own palette, independent of federfall's. The font set must be declared in `pubspec` **AND** in `AppTheme.fontFamilyFallback`. |
| **h7q.7** | go_router, url_strategy für Web, Startup-Weiche | P0, `flutter`+`infra`. The router only awaits server info on the **unauthenticated** path — which is why the map layer must be keyed on the resolved config. |
| **h7q.8** | Docker: `FROM zugvogel-pb-base` plus Web-Build; docker-compose und Overrides | P0, `infra`. `docker-compose.yml`, `.override.yml` for local dev, `.oidc.yml` for the optional identity-provider path. |
| **h7q.9** | CI-Workflow: Analyse, Format, Tests, Coverage-Gate | P0, `infra`+`quality`. From the **repo root**: `flutter analyze` (covers the packages — a subdirectory run does not) and `dart format --set-exit-if-changed`. Run each suite so its **own exit code survives**; piping through `grep` reports the filter's status and has hidden real failures before. |
| **h7q.10** | release-please: Version als App-zu-Server-Wire-Contract | P0, `infra`. `bump-minor-pre-major: false`, pinned explicitly. Breaking Conventional Commit for: any change to a hook route shape, a removed or renamed field the app reads, a newly required field, a rule tightening. Purely internal Dart refactors are **not** breaking — an enum rename is wire-safe because enums carry a wire value. |
| **h7q.11** | Migration 001: `organisations` mit einer geseedeten Zeile plus `users`-Erweiterung | P0, `backend`+`infra`. **Extend** the built-in `users` auth collection rather than recreating it, or the built-in email/password wiring is lost. Fields: `role` (member/coordinator), `org`, `is_active`, `invited_by`, `phone`. Seed exactly one organisation with a **stable id**. |
| **h7q.12** | Migration 002: Zugriffsregeln-Grundgerüst | P0, `backend`+`infra`. The rules **are** the security boundary, not the UI. Simpler than federfall: everything inside the org is readable by every active member — that is the point of the Gedächtnis. Coordinator-only: delete spots and areas, override rhythms, manage the team, read the audit log, export, reset a nest from `protected`. Every copied auth predicate ends with the `is_active` clause. |
| **h7q.13** | Migration 003: `geocode_cache`, `idempotency_keys`, Upload-Allowlist, Thumb-Größen, Dateifeld-Schutz | P0, `backend`+`infra`. The idempotency table is what makes the online-only decision survivable in the field. |
| **h7q.14** | Hooks verdrahten: `bootstrap_coordinator`, `info`, `web_headers`, `rate_limits`, `settings` | P0, `backend`+`infra`. `info` reports only `major.minor` on the unauthenticated endpoint (patch withheld to avoid fingerprinting) and local builds legitimately report `0.0`. `web_headers` **derives** the CSP origins from the same map URLs, so a prescribed tile source cannot be blocked by the policy that same server sent. |
| **h7q.15** | Server-Einrichtung: URL-Eingabe, Erreichbarkeitsprobe, Persistenz | P0, `flutter`+`infra`. *(No description in beads — see Open questions.)* Concept: the framing screen from federfall, unchanged in cut: server URL entry with a reachability probe. |
| **h7q.16** | Anmeldung: Mail und Passwort, Zurücksetzen-Template, Versionshinweis | P0, `flutter`+`infra`. On a version mismatch the login screen **replaces every sign-in control** with an update notice that names **which side must move**. It **fails open**: unreachable info, an unversioned dev build on either side, or an unparseable version never blocks. |
| **h7q.17** | Auth-Plumbing: aktueller Nutzer, Session-Refresh, Abmelden, `is_active`-Gate, `roles.dart` | P0, `flutter`+`infra`. *(No description in beads.)* Implies: current-user provider, session refresh, sign-out, an `is_active` gate on the client side, and the two-role model in `roles.dart` (member / coordinator). |
| **h7q.18** | OIDC als optionaler Pfad: Provisionierungs-Hook und compose-Datei | **P2**, `backend`+`infra`. Email plus password stays the default; OIDC is switchable for a group that has an identity provider. Code already exists in federfall (`oauth2_provisioning.pb.js`, `docker-compose.oidc.yml`). |
| **h7q.19** | Python-Regelsuite aufsetzen: `run.sh` und `test_rules.py` mit `is_active`-Sweep | P0, `backend`+`infra`+`quality`. Needs a **live** PocketBase. The sweep must fail on any rule that copied the auth predicate without the `is_active` clause. |
| **h7q.20** | ONBOARDING.md und der beads-Workflow | **P2**, `docs`+`infra`. *(No description in beads.)* |

**Phase 01 priority split:** P0 = h7q.1–5, 7–17, 19 (16 issues). P1 = h7q.6.
P2 = h7q.18, h7q.20.

**Phase 01 is blocked** until Phase 00 (`eiermann-d2a`) closes. The three
remaining Phase 00 blockers are `d2a.19` (build and version the
`zugvogel-pb-base` Docker image, P0), `d2a.20` (switch federfall onto zugvogel at
a pinned ref, suite green unmodified, P0) and `d2a.21` (zugvogel CLAUDE.md: the
three injection rules and the migration restriction, P1).

**Repo layout Phase 01 must establish** (from concept section 10):

```
eiermann/
├── AGENTS.md · CLAUDE.md · README.md · ONBOARDING.md
├── analysis_options.yaml        very_good_analysis, strict
├── pubspec.yaml                 pub workspace root
├── Dockerfile                   FROM zugvogel-pb-base + web build
├── docker-compose.yml           .override.yml · .oidc.yml
├── release-please-config.json   version = app↔server wire contract
├── .github/workflows/           ci · release-please (docker matrix + APKs)
├── apps/eiermann/
│   ├── dart_defines/            development · staging · production
│   ├── l10n.yaml
│   └── lib/
│       ├── bootstrap.dart · app/
│       ├── config/              app_environment · map_config
│       ├── core/                auth · pocketbase · server · realtime · error
│       ├── data/                repository_providers.dart
│       ├── features/            map/ spots/{areas,nests}/ visits/ findings/
│       │                        tours/ prospects/ dashboard/ statistics/
│       │                        reports/ admin/ auth/ server_setup/
│       │                        startup/ profile/
│       ├── l10n/arb/            app_de.arb (primary) · app_en.arb
│       ├── routing/ theme/ ui/
│   └── test/
├── packages/
│   ├── eiermann_models/         freezed + fromRecord, wire enums
│   └── eiermann_data/           PbRepository subclasses per collection
└── backend/pocketbase/
    ├── pb_migrations/           numbered, checked in, never hand-edited
    ├── pb_hooks/                app hooks (shared ones come from the base image)
    ├── typst/                   report.typ · summary.typ · shared_strings.json
    └── tests/                   run.sh · run_cron.sh · test_rules.py · test_cron.py
```

---

## 6. The twenty traps inherited from federfall

Each trap with the rule stated as an actionable instruction. These are to be
carried into `CLAUDE.md` as project instructions (h7q.2) and made enforceable by
the cross-cutting epic `eiermann-934`.

| # | Trap | **Rule (do this)** | Enforced by |
|---|---|---|---|
| 01 | PocketBase timestamps arrive as UTC; `DateFormat` and `MaterialLocalizations` do *not* convert — in CET everything after 22:00 UTC shows the previous day. Invisible on a UTC machine and in CI. | **Route every `DateTime`→text conversion through `formatLocalDate`, and nothing else.** | `934.1` sweep test fails on any other formatter |
| 02 | `record.get("settings")` hands JS a byte array; every property access is `undefined` and the code falls silently into its default. | **Keep exactly one JSON field in the database and exactly one reader (`lib_org.js`). A second `JSON.parse` in the repo is a review stopper.** | `934.2` |
| 03 | Computed view columns fall back to type `json`; `getString()` returns `"value"` *with* quotes. Only server-side readers see it and it fails silently. | **Ask the collection for `field.type()` and decode `json` columns; never sniff per value — a city named `true` also parses as JSON.** | `934.3` |
| 04 | Every hook handler runs in an isolated JSVM; file-level helpers are *not* visible inside the handler. | **Put `require()` inside the handler, in the absolute `${__hooks}` form. A module is the only way to share code between report and statistics.** | `934.4` |
| 05 | User input interpolated into a filter string = filter injection. | **Accept only `PbFilter` in the query surface, and produce it only via `filterExpr`, so the mistake is a compiler error.** | `934.5` |
| 06 | `?page=` over a list that grows while being read skips and duplicates rows. | **Use keyset pagination everywhere, plus the `PagedListTail` pattern with `loadMore`/`retryPage`. Debounce search fields — one keystroke is one request.** | `934.6` |
| 07 | Renaming a Dart enum breaks the mapping onto the stored strings. | **Give every enum a `wire` value: the exact string PocketBase stores. Renames are then wire-safe.** | `934.7` |
| 08 | A never-set PocketBase geoPoint arrives as `{lon:0, lat:0}` — a real place in the Gulf of Guinea. | **Make `GeoPoint.fromPb` treat `{0,0}` as `null`.** | zugvogel_core |
| 09 | Web has no system fonts: the engine fetches a Noto snippet from `fonts.gstatic.com` for every uncovered glyph, the CSP blocks it, and the engine retries on *every* layout — one arrow in an ARB string produced an endless error stream. | **Bundle fonts *and* list them in `fontFamilyFallback`; pin both halves with a test. A new non-ASCII character is only safe if the font set covers it.** | `h7q.6`, font pinning test |
| 10 | Map source as a compile-time constant: a self-hosted server cannot prescribe its own source, and a half-applied override names the wrong provider — a licensing problem. | **Take the map configuration at runtime from `/info`, all-or-nothing; derive the CSP from the *same* URLs so the server cannot block what it prescribes; key the layer on the resolved configuration.** | `h7q.14`, `h7q.7`, `upa.4` |
| 11 | A plain field reference in an UPDATE rule resolves against the *stored* record — the rule checks the old target and ignores the incoming one. | **What only a hook can see, a hook checks. Access rules stay the security boundary; hooks are the invariants.** | `h7q.12`, `jbk.6` |
| 12 | Multiple records over multiple requests: an abort in the middle leaves a state indistinguishable from an intention. | **One Besuch = one route, one transaction, one idempotency key.** | `jbk.5` |
| 13 | Client and server drift apart; the user sees inexplicable errors. | **Treat the major version as the wire contract. Wire-breaking commits are `feat!:`. The check fails *open* — unreachable `/info` or a dev build never blocks — and the message names which side must move.** | `h7q.10`, `h7q.16` |
| 14 | `cronAdd` jobs are invisible to the rule suite: nothing can trigger them, so nobody tests them. | **Run a separate harness with a rewritten schedule against a copy of the hooks. A window measured in days cannot be reached by backdating (`created` belongs to the server) — so make the window vanishingly small in the test.** | `jbk.15`, `tests/run_cron.sh` |
| 15 | An audit entry that looks ids up tells the past wrongly: the target may be deleted or renamed. | **Store text snapshots at the time of the event. An id without a label next to it is a bug. Keep values as `wire` strings and translate only in the client.** | `uwd.3`, `uwd.4` |
| 16 | Multiple derivations of the same state drift. And: after-success hooks re-read the same object — two saves produce two transitions from one stale original. | **One derivation (`lib_rhythm.js`), every writer calls it. Save the surviving record exactly once.** | `jbk.3` |
| 17 | Cascading delete: a forgotten collection is not left behind but *destroyed* — and the response is a 200. | **Put every collection with a `nest` or `spot` relation in the delete-effect registry, and make the suite fail in both directions: an entry without a cascade, and a cascade without an entry.** | `bmg.12`, `934` |
| 18 | Curated code lists go stale: they contain dead entries and lack new ones. | **Build vocabulary as a view over the DISTINCT values actually recorded, per org. No seeding, nothing dead in the picker. Name the price where it occurs: two spellings are two rows, and nothing normalises behind your back.** | `3is.1`, `3is.3` |
| 19 | Codegen as an optional step: stale `.g.dart` files produce errors that look like something else. | **Run `flutter gen-l10n` after every ARB change and `build_runner build` after every `@riverpod`/`@freezed` change. Generated code is gitignored and built, not checked in.** | `934.8`, `h7q.4`, `h7q.5` |
| 20 | Hand-rolled versions and tags run away from reality. | **Let release-please drive the version from Conventional Commits. Never touch `pubspec.yaml` by hand. Merging the standing release PR builds the image and the signed APKs.** | `h7q.10` |

A 21st, repo-layout-specific trap is called out separately in section 10 of the
concept and is worth treating as a rule: **run `flutter analyze` from the repo
root.** A run inside `apps/eiermann` analyses only the app — that is how nine
findings in `federfall_data` shipped unnoticed. Inside the packages themselves
`dart analyze` additionally crashes the analysis server, so the root run *is*
their lint gate. (Tracked as `934.9` and `h7q.9`.)

---

## 7. UI surfaces

Eleven views, "one of which counts". The map is the entry point; **the Spot detail
is the product.** Everything else is a feeder.

### Spot detail — the first second

Two things must stand there without scrolling and without thinking: the overview
photo with state-coloured pins, so you orient yourself *physically*, and below it
one line per nest with content and age — urgent first.

```
┌──────────────────────────────────────────────────┐
│  Bahnhofstr. 12                    ● aktiv       │
│  fällig heute · Nachkontrolle Nest 3             │
├──────────────────────────────────────────────────┤
│  Bereich: Dachboden Nord            1 / 2  ›     │
│  ┌────────────────────────────────────────────┐  │
│  │ ░░░░░░░░░░ Übersichtsfoto ░░░░░░░░░░░░░░░░ │  │
│  │ ░░░ ① ░░░░░░░░░░░░░ ② ░░░░░░░░░░░░░░░░░░░░ │  │
│  │ ░░░░░░░░░░░ ③⚠ ░░░░░░░░░ △④ ░░░░░░░░░░░░░░ │  │
│  └────────────────────────────────────────────┘  │
├──────────────────────────────────────────────────┤
│ ⚠ N3  Balken links   1 Kunst · 1 echt    2 Tage  │
│   N1  Balken rechts  2 Kunst             34 Tage │
│   N2  Fensternische  leer                12 Tage │
│ △ N4  Mauernische    Dohle — nicht anfassen      │
├──────────────────────────────────────────────────┤
│  Einpacken: 3 Attrappen                          │
│  Zugang: Schlüssel bei Hausmeister Kaya, 2. OG   │
├──────────────────────────────────────────────────┤
│  [ Besuch starten ]        [ Nicht geprüft ]     │
└──────────────────────────────────────────────────┘
```

- **"Einpacken: 3 Attrappen"** is called the smallest feature with the highest
  everyday value: computable from the Ist-Gelege, and it replaces guessing at the
  car.
- **The Zugang line** is the actual answer to "die Übergabe ist schmerzhaft" —
  not a participant list, but what the next person needs to get in at all.

### The eleven screens

| Screen | Job | Specifics |
|---|---|---|
| **Karte** (map) | Entry point. Spots as pins, coloured by urgency: overdue, Halbgelege, due soon, in order, Erkundung, paused, closed | Reads **only** `spot_overview`. Clustering, filter chips, search, "in meiner Nähe" via GPS. Map source comes at runtime from `/api/eiermann/info`, not from the build |
| **Dashboard** | What is to be done. **Open Halbgelege always at the very top**, then overdue, then due today | Shows an open tour run as "Tour 1 fortsetzen". Erkundung spots waiting for a reply as their own block |
| **Spot-Detail** | The dossier. Bereiche, Nester, contacts & access, history, Rhythmus explanation | The history is **one** chronology of visits, checks, findings and phase changes — federfall's rule "one consistent view instead of fragmented sections" |
| **Bereichs-Editor** | Take/replace photo, place and move pins | After a photo replacement a **forced review pass**: old and new photo side by side, every pin confirmed or moved once |
| **Nest-Sheet** | Egg slots with kind and age. Swap, add egg, nest empty, nest is gone, change species | For `protected` the swap path is **not disabled but replaced** — by an explanation of why not |
| **Besuchsablauf** (visit flow) | Work through the nests, record Funde, note and photos, finish | Everything in memory until completion; one call, one idempotency key, one clear retry path. Alternative: "Nicht geprüft" with reason |
| **Touren** | Manage templates; start, work, deviate from, finish a run | Progress as an ordered list; adding and skipping a spot are **equal-rank actions, not error paths** |
| **Erkundung** | The funnel: unberührt → Mieter → Eigentümer → erlaubt/abgelehnt | Grouped by stage, with contact and next action. Answers "bei wem hängt es?" |
| **Statistik** | Eggs removed over time, visits, spots per phase, findings | Aggregates **nothing** in the client — one call to `/stats`, the same `lib_stats.js` the report uses. Pie charts limited to three hues + "Sonstige" |
| **Bericht** | Choose period and format, share file | Authority PDF per address, funder summary, CSV. **No encoder in the client** |
| **Verwaltung** | Invite team, org settings (the Rhythmus numbers!), audit log | Koordination only. Making the Rhythmus numbers editable here is *the reason* they live in `settings` |

Plus the framing screens carried over from federfall, unchanged in cut: server
setup with URL entry and reachability probe, login with version check, profile,
startup gate.

---

## 8. Deliberate decisions a reader might otherwise get wrong

Every row of the concept's decision table is a decision with its price; the third
column ("what this cannot do") is the important one.

### Explicit non-goals

- **No offline.** Online-only, like federfall: every read and write goes to the
  server with a short timeout instead of hanging. **No local cache, no sync, no
  conflict resolution** — the most expensive item is dropped. Price: in a cellar
  without reception you cannot save. Mitigation is the in-memory visit form plus
  idempotency key, *not* offline capability.
- **No push notifications.** Reminders live only in the app: dashboard and map
  colour. No FCM/APNs dependency, no notification permissions, no server
  scheduler except the pause-resume cron.
- **No presence and no time tracking** on visits. Price: funder reports cannot
  show volunteer hours. The answer to "handover is painful" is the Spot dossier,
  not the attendance list.
- **No population counts.** Nests and eggs, nothing else. Faster tours. Price:
  "is the programme working?" can only be answered via eggs removed and nest
  activity, not via bird counts.
- **No individual egg tracking.** "Which of the two eggs is which" is fiction in
  the field.
- **No dummy-egg inventory and no per-egg provenance.** Only **removed real
  eggs** are counted — that is the programme's key metric.
- **No consent documents, no expiry dates** on contacts. Role, name, phone, mail,
  note — enough for "whom do I call" and "may we go in". Price: **the app is
  explicitly not proof of a permission.**
- **No self-signup.** Koordination invites. Email + password is the default; OIDC
  is switchable.
- **No UI for creating further organisations.** Multi-org is *built* (org
  relation everywhere, org-scoped access rules, schema-driven `lib_org_scope.js`
  hook) but exactly one org is seeded. Costs almost nothing on day one and can
  never need retrofitting.
- **No data bridge to federfall.** Same architecture, same library, separate
  instances and release cycles. A chick that goes into care is a note here.

### Rejected alternatives (named as rejected)

- **The drawn nest with tappable eggs** — cuter, "but nobody recognises a roof
  beam in it". Chosen instead: real overview photo with state-coloured pins plus
  an egg-slot row.
- **Seven individual REST writes for a visit** — chosen instead: one
  transactional endpoint with an idempotency key.
- **federfall's three role levels** — too much ceremony for a volunteer group.
  Chosen instead: two roles, member + Koordination; everybody does field work and
  sees everything.
- **Chaining nest identity** — an emptied nest becomes `gone`; a rebuild in the
  same corner is a **new record**. Simplest rules. Price: the story of a corner
  fragments — the Bereich photo carries the continuity, not the record.
- **Isolated report handlers** — one route with `?format=` branching, because
  isolated handlers cannot share the collection code.
- **Private-by-default access rules** (federfall's pattern) — everything inside
  the org is readable by every active member; that is the point of a Gedächtnis.

### Constraints and invariants that are not negotiable

- **Migrations cannot be shared between federfall and eiermann.** A PocketBase
  migration is a historical fact, not a library function: federfall created
  `organisations` and the `users` extension under `1700000001` in 2024, and that
  file cannot be retroactively replaced by a shared one. Therefore: hooks, Typst,
  tests and CI are genuinely shared (replaceable stateless files); **migrations
  are shared as templates and checked into eiermann as its own numbered files —
  copied, not linked.** Backend material ships via a base image
  (`ghcr.io/…/zugvogel-pb-base:vX.Y.Z`) so the library version is visible in the
  image rather than hidden in a submodule. Shared hooks occupy a reserved
  namespace `zv_*.pb.js` so an app hook can never accidentally overwrite them.
- **zugvogel is pinned by commit hash, not by tag** (beads memory
  `zugvogel-git-dep-modell`). Repo: `git@github.com:jhbruhn/zugvogel.git`
  (public); consumers declare the HTTPS URL
  `https://github.com/jhbruhn/zugvogel.git` and pin a **commit hash** — a tag can
  be moved, pub caches per ref, and then two machines resolve the same
  declaration to different code. There are deliberately **no releases**:
  release-please runs and keeps an open release PR as a summary that is **not
  merged**. Verified 2026-08-21 against the real remote. `pubspec.lock` is not
  committed in zugvogel.
- **Three injection boundaries make the broad shared package viable** — if they
  erode, the two product designs weld together:
  1. **No strings in the package.** No widget imports an `l10n` class; text comes
     via an injected `ZugvogelStrings` object each app fills from its own ARB
     files. A widget that knows "Abbrechen" itself is a bug.
  2. **No colours in the package.** Widgets read
     `Theme.of(context).colorScheme` and a `ZugvogelSemantics` `ThemeExtension`
     for good/warning/critical. Eiermann's palette and federfall's are
     independent.
  3. **No configuration in the package.** No `AppEnvironment` access, no
     compile-time defines. What is needed is passed in.
  Practically: eiermann may **copy** a widget for as long as it is unclear whether
  it is generic. Promotion happens only when both apps need the same thing and
  the two copies would be identical. Concrete warning sign: the first pull request
  that changes a widget in `zugvogel_ui` *so that* eiermann looks different — then
  the widget belongs back in the app.
- **Schema exclusively via numbered, checked-in JS migrations. Never by hand in
  the admin UI.**
- **A skipped visit moves nothing** — neither streak nor date. The spot stays
  overdue.
- **`follow_ups.due_at` is stored, not derived** — a plan is a fact.
- **`spot.next_due_at` and `nest.next_due_at` are derived but stored** so the map
  colours in one query.
- **`pin_x`/`pin_y` are normalised 0…1, never pixels.**
- **Nothing drifts silently on photo replacement:** pins keep x/y but the area is
  `pins_need_review` until every pin is confirmed or moved; the old photo stands
  next to the new one for exactly one generation.
- **`unknown` species is a visible open question, never a silent assumption of
  "city pigeon".**
- **iOS is deliberately last** (Phase 08): it is distribution, not product — an
  Apple developer account, signing, review and a permanent third platform.
- **Tests:** rule tests in **Python against a running PocketBase**
  (`tests/run.sh`) — migrations and hooks cannot be tested from the Flutter
  suite. Cron tests separately (`tests/run_cron.sh`) in a throwaway container
  against a copy of `pb_hooks` with a rewritten schedule. Flutter widget and unit
  tests with `mocktail` overrides of the repository providers, with a coverage
  threshold in CI. Sweep tests (date formatter, font fallback) ship from the
  shared package and run in eiermann from day one.
- **Push is not part of session completion in this repo** (repo CLAUDE.md, issue
  `eiermann-h7q.2`): commit directly on `main`, push only when asked. There is no
  git remote yet.

### Known risks the concept names (with its own smallest-extension answers)

| Risk | Concept's position |
|---|---|
| **Species identification** | The largest real risk; the app can only frame it, not solve it. The guard protects only what someone has marked. Recommendation: carry `unknown` as a visible open question and ship a short jackdaw-vs-city-pigeon picture sheet in the onboarding docs — outside the app, but linked (`uwd.9`) |
| **No offline** | Deliberate and well cushioned by the idempotency key, but the form does not survive killing the app. If it hurts three times in the field, the smallest extension is a **persistent draft of the visit body on the device** — *not* an offline cache of the whole database |
| **Nest identity** | "New nest, no chaining" fragments a corner's history. If "this corner keeps getting rebuilt" turns out to be the important insight, the retrofit is a nullable `predecessor` field plus a view — additive, not wire-breaking |
| **No hours, no attendance** | If a funder demands it, the smallest addition is a `participants` field and two timestamps **on the tour run** — not on the visit, or every spot becomes a time clock |
| **Broad shared package** | The three injection rules are what make it viable; if they erode the two product designs weld together |
| **iOS** | Permanent cost; hence Phase 08 |
| **Legal frame** | Clutch swapping needs the owner side's consent and in many municipalities runs under a Stadttaubenkonzept. The app carries contacts and Erkundung states but is explicitly **not** proof of a permission. If an authority later wants documents, that is a file field and an expiry date on the spot |

---

## Open questions

Things an implementer needs that the concept does not settle. The concept itself
lists the first three under "Noch offen".

1. **The concrete Rhythmus numbers for launch.** The defaults in the concept
   (`7 / 3 / [7,14,28] / 4 / true`) are explicitly **proposals**, not decisions.
2. **Who the first report recipient is, and in what form.** This shapes the Typst
   authority report (`fi2.5`).
3. **Whether "Bereich" should really be called that in the UI.**
4. **`prospect_stage` wire values.** The concept names the stages in German prose
   (unberührt / Mieter gesprochen / Eigentümer gesprochen / erlaubt / abgelehnt)
   but gives no `wire` strings, unlike every other enum. Same for
   `spots.closed_reason`, `spot_contacts.role` and `visits.skip_reason`.
5. **How `nest_checks.state` values other than `empty`, `partial` and the
   egg-bearing ones affect the ladder.** The rules state that `empty` increments
   the streak and any sign of life resets it, but `untouched`, `not_reachable`,
   `gone` and `protected` are not assigned a Rhythmus effect explicitly. `gone`
   presumably takes the nest out of the due set via `nests.status`.
6. **Whether a `not_reachable` nest check counts as a "completed check" for
   `nest.next_due_at = last completed check + interval_days`.** The skipped-visit
   rule is explicit at visit level; the per-nest analogue is not stated.
7. **Field types and lengths** for every collection: which fields are required,
   which have defaults, which are indexed. Only `geo` (geoPoint), `settings`
   (JSON) and the scalar counters (`number`) are typed explicitly in the concept.
8. **Cascade behaviour per relation.** The delete-effect registry is mandated
   (`bmg.12`, trap 17) but the concept does not say which relations cascade and
   which block — that has to be decided per collection.
9. **Whether `nest_eggs.slot_index` is dense/stable across checks**, i.e. whether
   a removed egg's slot index is reused or left as a hole.
10. **`spot_overview` urgency-rank definition.** The view is required to expose a
    "Dringlichkeitsrang" and the map colours from it, but the ranking function and
    the "bald fällig" threshold are not specified.
11. **`h7q.15`, `h7q.17` and `h7q.20` have no beads description.** Their scope has
    to be read out of the concept's framing-screens paragraph and section 08.
12. **Where the Phase 00 remainder lands relative to Phase 01 start.** Phase 01 is
    formally blocked by `d2a.19`/`d2a.20`/`d2a.21`; the concept says Phases 00 and
    01 are both "immediately actionable", so whether Phase 01 work may start in
    parallel with the last three Phase 00 issues is not decided.
13. **Audit-event registry contents.** `audit_events` stores label snapshots and
    `uwd.3` mentions "Registries", but which domain writes are audited (phase
    changes? species changes? contact edits?) is not enumerated.
14. **Rate limits and upload allowlist specifics** (`h7q.13`, `h7q.14`): the file
    types, thumb sizes and per-route limits are not given.
