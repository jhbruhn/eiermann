# federfall — effective PocketBase schema and access rules

**What this is.** A reference digest of the *end state* of federfall's PocketBase
schema: the 44 application collections, their fields, and — most importantly —
the five API access rules on each, quoted verbatim. The access rules *are* the
security model; almost nothing about the tenancy or role model is enforced
anywhere else.

**How it was produced.** Not by reading migrations. The end state was **actually
rendered**: the `federfall-pocketbase:0.39.8` image (the `backend` target of the
repo-root `Dockerfile`, as `backend/pocketbase/tests/run.sh` builds it) was run
`migrate up` against a fresh throwaway `pb_data` dir, applying all 93 migrations
in `backend/pocketbase/pb_migrations/` in order; a superuser was upserted; the
server was started; and `GET /api/collections?perPage=200` was dumped as JSON.
Everything in sections 1–3 is transcribed mechanically from that dump, so later
migrations that alter or delete earlier work are already accounted for. Sections
4–5 are analysis, cross-checked against `backend/pocketbase/pb_hooks/`.

**Read this first — three things the rules assume.**

1. **`@request.body.<field>:isset = false` means "the request may not mention
   this field at all"** — not "must equal the stored value". Sending the field
   with an identical value still fails. It is the schema's only field-level
   write guard.
2. **In an update rule, a plain field reference resolves against the STORED
   record, not the incoming body.** So `case.org = @request.auth.org` in an
   update rule checks the parent the row *currently* has. This is why every
   parent relation is frozen with an `:isset = false` guard, and why the
   cross-tenant relation check had to move into a hook.
3. **`?=` is the "any of" operator over a multi-valued path.** It appears
   wherever a back-relation is traversed, e.g.
   `case_shares_via_case.shared_with ?= @request.auth.id` = "some share on this
   case names me".

## 1. Collection inventory

44 application collections — 34 `base`, 9 `view`, 1 `auth`. The five PocketBase system collections (`_superusers`, `_mfas`, `_otps`, `_externalAuths`, `_authOrigins`) are omitted throughout.

| Collection | Type | Purpose |
| --- | --- | --- |
| `users` | auth | Org members; carries `role` (carer/coordinator/supervisor/guest), `org`, `is_active` — the three variables every access rule reads. |
| `organisations` | base | The tenant. One row per rescue organisation; `settings` json holds per-org config. |
| `animals` | base | The bird as a lasting identity across admissions — species, sex, `lifetime_status`, `current_aviary`, protected photo. |
| `finders` | base | PII of the member of the public who found a bird: name, phone, email, address, plus a `pii_purged` retention flag. |
| `cases` | base | One admission of one animal: intake data, find location/geo, `status`, `active_carer`, `finder`, admission reasons. |
| `markings` | base | Rings/bands and other identifiers applied to an animal, with scheme, colour, apply/remove dates. |
| `conditions` | base | Per-org code list of diagnoses; flags `is_notifiable` and `is_contagious`. |
| `case_conditions` | base | A diagnosis attached to a case — either a `condition` code-list entry or `free_text`, with certainty and dates. |
| `weights` | base | Weight measurements, keyed to an animal and optionally to a case. |
| `medications` | base | A prescription on a case: drug, dose, route, schedule (`frequency_kind`, `interval_hours`, on/off cycle). |
| `journal_entries` | base | Free-text log with protected attachments, hanging off EITHER a case or an aviary. |
| `placements` | base | Where an animal is being held and hand-offs between carers. |
| `aviaries` | base | A long-term enclosure with a required `keeper` (the user who is responsible for it). |
| `dispositions` | base | How a case ended: released / placed in aviary / died / euthanized / transferred / returned to owner. |
| `case_shares` | base | Explicit grant of `read` or `edit` on one case to one other user — the delegation primitive. |
| `medication_administrations` | base | A single dose actually given, denormalising drug/dose from the prescription. |
| `case_summaries` | view | Read-only per-case rollup (status, dates, carer, derived `ended_at` from the latest disposition). |
| `case_activity` | view | Per-case `last_activity` timestamp, max of the case and all its child rows — for "stale case" lists. |
| `follow_ups` | base | A dated to-do on a case (`due_at` / `done_at`). |
| `exams` | base | A physical examination: body condition, hydration, mentation, mucous membranes, temperature. |
| `exam_findings` | base | Per-body-system normal/abnormal finding belonging to one exam. |
| `geocode_cache` | base | Server-side cache of forward/reverse geocoding responses with TTL. No client access at all. |
| `quarantine_records` | base | A quarantine period set on a case (`quarantine_until`, reason, who set it). |
| `case_quarantine` | view | The latest quarantine record per case, flattened for querying. |
| `admission_reasons` | base | Per-org code list of intake reasons. |
| `marking_types` | base | Per-org code list of marking/ring types. |
| `medication_routes` | base | Per-org code list of administration routes. |
| `animal_species` | view | Distinct species strings per org — an autocomplete source. |
| `idempotency_keys` | base | Replay protection for the custom write routes: (endpoint, user, key) -> stored response, with TTL. |
| `aviary_stays` | base | Derived history of which animal was in which aviary when. Written only by a hook. |
| `egg_records` | base | Eggs laid by a resident animal: count, fertility, fate, protected photos. |
| `medication_products` | base | Per-org drug catalogue: default dose rate, range, concentration, route, schedule template. |
| `condition_labels` | view | Distinct condition labels per org with case counts — code-list entries plus free-text ones. |
| `case_report_rows` | view | Flattened one-row-per-case reporting extract (species, outcome, markings, reasons) for the annual report. |
| `vet_appointments` | base | A scheduled vet visit on a case, with reminder lead time and mute flag. |
| `audit_events` | base | Append-only audit log: actor, action, subject, changes, ip, user agent, request id. |
| `case_carer_load` | view | Open-case count per carer per org — a coordinator triage aid. |
| `microscopy_finding_types` | base | Per-org code list of microscopy findings, scoped by sample type. |
| `microscopy_samples` | base | A crop swab or fecal sample examined in-house/vet/lab, with protected image and video attachments. |
| `microscopy_findings` | base | A finding on one sample, with a plus/plus_plus/plus_plus_plus severity. |
| `sponsorships` | base | Donor PII (name, pronouns, address, mobile) plus amount and interval, optionally tied to an animal. |
| `vaccinations` | base | A vaccine dose given to an animal, with batch, series, `next_due_at`, protected attachments. |
| `vaccine_labels` | view | Distinct vaccine/target pairs per org with use counts and last-used date. |
| `medication_due` | view | Computed next-due dose per active prescription, restricted to the requesting carer. |

## 2. Fields, relations and indexes

Notation: `REQ` = required. Relations show `-> target (cascade)` where *cascade* is the `cascadeDelete` flag. `PROTECTED` marks a file field that needs a short-lived file token to read. Auto fields (`created`, `updated`) and the system `id` are listed once here and then omitted per-collection.

Every non-view collection has `id text REQ (system, `^[a-z0-9]+$`, max 15)` and autodate `created`; all but `idempotency_keys` and `audit_events` also have autodate `updated`.

### `users` (auth)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `password` | password | yes | hidden; system |
| `tokenKey` | text | yes | max 60; hidden; system |
| `email` | email | yes | system |
| `emailVisibility` | bool |  | system |
| `verified` | bool |  | system |
| `name` | text |  | max 255 |
| `avatar` | file |  | maxSelect=1 |
| `role` | select | yes | values: `carer`, `coordinator`, `supervisor`, `guest` |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |
| `is_active` | bool |  |  |
| `invited_by` | relation -> `users` |  | cascadeDelete=false |
| `phone` | text |  | max 50 |
| `mfa_enabled` | bool |  |  |

Indexes:

- **UNIQUE** `CREATE UNIQUE INDEX `idx_tokenKey__pb_users_auth_` ON `users` (`tokenKey`)`
- **UNIQUE** `CREATE UNIQUE INDEX `idx_email__pb_users_auth_` ON `users` (`email`) WHERE `email` != ''`

### `organisations` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `name` | text | yes | max 200 |
| `contact_email` | email |  |  |
| `contact_phone` | text |  | max 50 |
| `settings` | json |  |  |

### `animals` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `name` | text |  | max 100 |
| `species` | text | yes | max 100 |
| `sex` | select |  | values: `male`, `female`, `unknown` |
| `is_owned` | bool |  |  |
| `lifetime_status` | select |  | values: `in_care`, `at_large_released`, `in_aviary`, `deceased` |
| `tags` | json |  |  |
| `notes` | text |  | max 5000 |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |
| `current_aviary` | relation -> `aviaries` |  | cascadeDelete=false |
| `photo` | file |  | maxSelect=1; **PROTECTED** |

### `finders` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `first_name` | text |  | max 100 |
| `last_name` | text |  | max 100 |
| `organisation` | text |  | max 200 |
| `phone` | text |  | max 50 |
| `alt_phone` | text |  | max 50 |
| `email` | email |  |  |
| `address` | text |  | max 300 |
| `postal_code` | text |  | max 20 |
| `city` | text |  | max 150 |
| `region` | text |  | max 150 |
| `notes` | text |  | max 5000 |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |
| `pii_purged` | bool |  |  |

### `cases` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `animal` | relation -> `animals` | yes | cascadeDelete=**true** |
| `case_number` | text |  | max 20 |
| `age_class` | select |  | values: `squab`, `fledgling`, `immature`, `adult` |
| `admitted_at` | date |  |  |
| `found_at` | date |  |  |
| `admitted_by` | relation -> `users` |  | cascadeDelete=false |
| `transported_by` | text |  | max 200 |
| `finder` | relation -> `finders` |  | cascadeDelete=false |
| `find_location` | text |  | max 300 |
| `find_geo` | geoPoint |  |  |
| `city` | text |  | max 150 |
| `region` | text |  | max 150 |
| `intake_weight_g` | number |  | min 0 |
| `intake_notes` | text |  | max 5000 |
| `intake_photos` | file |  | maxSelect=20; **PROTECTED** |
| `status` | select |  | values: `in_care`, `ready_for_release`, `disposed` |
| `is_releasable` | bool |  |  |
| `active_carer` | relation -> `users` |  | cascadeDelete=false |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |
| `admission_reasons` | relation -> `admission_reasons` |  | cascadeDelete=false; maxSelect=99 |

Indexes:

- **UNIQUE** `CREATE UNIQUE INDEX `idx_cases_case_number` ON `cases` (`org`, `case_number`)`

### `markings` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `animal` | relation -> `animals` | yes | cascadeDelete=**true** |
| `code` | text |  | max 100 |
| `scheme_org` | text |  | max 200 |
| `colour` | text |  | max 100 |
| `applied_at` | date |  |  |
| `applied_by` | relation -> `users` |  | cascadeDelete=false |
| `applied_in_case` | relation -> `cases` |  | cascadeDelete=false |
| `removed_at` | date |  |  |
| `removed_reason` | text |  | max 300 |
| `is_active` | bool |  |  |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |
| `type` | relation -> `marking_types` | yes | cascadeDelete=false |
| `present_at_find` | bool |  |  |

Indexes:

- `CREATE INDEX `idx_markings_code` ON `markings` (`code`)`

### `conditions` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `label` | text | yes | max 200 |
| `is_notifiable` | bool |  |  |
| `description` | text |  | max 2000 |
| `active` | bool |  |  |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |
| `is_contagious` | bool |  |  |

### `case_conditions` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `case` | relation -> `cases` | yes | cascadeDelete=**true** |
| `condition` | relation -> `conditions` |  | cascadeDelete=false |
| `free_text` | text |  | max 300 |
| `certainty` | select |  | values: `suspected`, `confirmed` |
| `onset_date` | date |  |  |
| `resolved_date` | date |  |  |
| `notes` | text |  | max 2000 |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |

### `weights` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `case` | relation -> `cases` |  | cascadeDelete=false |
| `measured_at` | date |  |  |
| `weight_g` | number | yes | min 0 |
| `notes` | text |  | max 1000 |
| `author` | relation -> `users` |  | cascadeDelete=false |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |
| `animal` | relation -> `animals` | yes | cascadeDelete=**true** |

### `medications` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `case` | relation -> `cases` | yes | cascadeDelete=**true** |
| `drug` | text | yes | max 200 |
| `dose` | number |  | min 0 |
| `dose_unit` | text |  | max 50 |
| `started_at` | date |  |  |
| `ended_at` | date |  |  |
| `is_controlled` | bool |  |  |
| `instructions` | text |  | max 2000 |
| `prescribed_by` | text |  | max 200 |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |
| `frequency_kind` | select |  | values: `once`, `scheduled`, `as_needed` |
| `interval_hours` | number |  | min 1 |
| `route` | relation -> `medication_routes` |  | cascadeDelete=false |
| `dose_rate` | number |  | min 0 |
| `concentration_per_ml` | number |  | min 0 |
| `cycle_on_days` | number |  | min 1, int only |
| `cycle_off_days` | number |  | min 1, int only |

### `journal_entries` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `case` | relation -> `cases` |  | cascadeDelete=**true** |
| `entry_at` | date |  |  |
| `text` | text | yes | max 10000 |
| `attachments` | file |  | maxSelect=20; **PROTECTED** |
| `author` | relation -> `users` |  | cascadeDelete=false |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |
| `aviary` | relation -> `aviaries` |  | cascadeDelete=**true** |

### `placements` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `case` | relation -> `cases` | yes | cascadeDelete=**true** |
| `moved_in_at` | date |  |  |
| `carer` | relation -> `users` |  | cascadeDelete=false |
| `where_holding` | text |  | max 200 |
| `area` | text |  | max 200 |
| `enclosure` | text |  | max 200 |
| `from_user` | relation -> `users` |  | cascadeDelete=false |
| `to_user` | relation -> `users` |  | cascadeDelete=false |
| `condition_at_handoff` | text |  | max 2000 |
| `comments` | text |  | max 2000 |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |

### `aviaries` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `name` | text | yes | max 200 |
| `keeper` | relation -> `users` | yes | cascadeDelete=false |
| `location` | text |  | max 300 |
| `location_geo` | geoPoint |  |  |
| `capacity` | number |  | min 0 |
| `active` | bool |  |  |
| `notes` | text |  | max 2000 |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |

### `dispositions` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `case` | relation -> `cases` | yes | cascadeDelete=**true** |
| `type` | select | yes | values: `released`, `placed_in_aviary`, `died`, `euthanized`, `transferred`, `returned_to_owner` |
| `disposed_at` | date |  |  |
| `reason` | text |  | max 2000 |
| `performed_by` | relation -> `users` |  | cascadeDelete=false |
| `release_location` | text |  | max 300 |
| `release_geo` | geoPoint |  |  |
| `release_type` | text |  | max 100 |
| `aviary` | relation -> `aviaries` |  | cascadeDelete=false |
| `transfer_type` | text |  | max 100 |
| `transfer_destination` | text |  | max 300 |
| `vet_signed_off` | bool |  |  |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |
| `vet` | text |  | max 200 |

### `case_shares` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `case` | relation -> `cases` | yes | cascadeDelete=**true** |
| `shared_with` | relation -> `users` | yes | cascadeDelete=**true** |
| `access` | select | yes | values: `read`, `edit` |
| `shared_by` | relation -> `users` |  | cascadeDelete=false |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |

Indexes:

- **UNIQUE** `CREATE UNIQUE INDEX `idx_case_shares_case_user` ON `case_shares` (`case`, `shared_with`)`

### `medication_administrations` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `case` | relation -> `cases` | yes | cascadeDelete=**true** |
| `medication` | relation -> `medications` |  | cascadeDelete=false |
| `drug` | text | yes | max 200 |
| `dose` | number |  | min 0 |
| `dose_unit` | text |  | max 50 |
| `administered_at` | date | yes |  |
| `administered_by` | relation -> `users` |  | cascadeDelete=false |
| `notes` | text |  | max 2000 |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |
| `route` | relation -> `medication_routes` |  | cascadeDelete=false |
| `weight_g_used` | number |  | min 0 |
| `volume_ml` | number |  | min 0 |

### `case_summaries` (view)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `animal` | relation -> `animals` | yes | cascadeDelete=**true** |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |
| `case_number` | text |  | max 20 |
| `status` | select |  | values: `in_care`, `ready_for_release`, `disposed` |
| `admitted_at` | date |  |  |
| `found_at` | date |  |  |
| `active_carer` | relation -> `users` |  | cascadeDelete=false |
| `ended_at` | json |  |  |

### `case_activity` (view)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |
| `last_activity` | json |  |  |

### `follow_ups` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `case` | relation -> `cases` | yes | cascadeDelete=**true** |
| `due_at` | date | yes |  |
| `note` | text |  | max 2000 |
| `done_at` | date |  |  |
| `created_by` | relation -> `users` |  | cascadeDelete=false |
| `org` | relation -> `organisations` |  | cascadeDelete=false |

### `exams` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `case` | relation -> `cases` | yes | cascadeDelete=**true** |
| `animal` | relation -> `animals` | yes | cascadeDelete=**true** |
| `examined_at` | date |  |  |
| `examiner` | relation -> `users` |  | cascadeDelete=false |
| `body_condition` | number |  | min 1, max 5, int only |
| `hydration` | select |  | values: `normal`, `mild`, `moderate`, `severe` |
| `mentation` | select |  | values: `bright`, `quiet`, `depressed`, `unresponsive` |
| `notes` | text |  | max 2000 |
| `org` | relation -> `organisations` |  | cascadeDelete=false |
| `temperature` | number |  |  |
| `mm_color` | select |  | values: `pink`, `pale`, `cyanotic`, `icteric`, `injected` |
| `mm_texture` | select |  | values: `moist`, `tacky`, `dry` |

### `exam_findings` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `exam` | relation -> `exams` | yes | cascadeDelete=**true** |
| `system` | select | yes | values: `eyes`, `beak_nares`, `oral`, `integument`, `wings`, `legs_feet`, `keel`, `respiratory`, `coelom`, `neuro`, `vent` |
| `status` | select | yes | values: `normal`, `abnormal` |
| `note` | text |  | max 2000 |
| `org` | relation -> `organisations` |  | cascadeDelete=false |

### `geocode_cache` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `kind` | select | yes | values: `forward`, `reverse` |
| `cache_key` | text | yes | max 512 |
| `response` | json | yes |  |
| `result_count` | number |  |  |
| `hits` | number |  |  |
| `expires_at` | date | yes |  |

Indexes:

- **UNIQUE** `CREATE UNIQUE INDEX `idx_geocode_cache_key` ON `geocode_cache` (`kind`, `cache_key`)`
- `CREATE INDEX `idx_geocode_cache_expires` ON `geocode_cache` (`expires_at`)`

### `quarantine_records` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `case` | relation -> `cases` | yes | cascadeDelete=**true** |
| `set_at` | date |  |  |
| `quarantine_until` | date | yes |  |
| `reason` | text |  | max 2000 |
| `set_by` | relation -> `users` |  | cascadeDelete=false |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |

### `case_quarantine` (view)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |
| `quarantine_until` | json |  |  |
| `set_at` | json |  |  |

### `admission_reasons` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `label` | text | yes | max 200 |
| `active` | bool |  |  |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |

### `marking_types` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `label` | text | yes | max 200 |
| `active` | bool |  |  |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |

### `medication_routes` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `label` | text | yes | max 200 |
| `active` | bool |  |  |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |

### `animal_species` (view)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |
| `species` | text | yes | max 100 |

### `idempotency_keys` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `endpoint` | text | yes | max 64 |
| `key` | text | yes | max 64 |
| `user` | relation -> `users` | yes | cascadeDelete=**true** |
| `response` | json | yes |  |
| `expires_at` | date | yes |  |

Indexes:

- **UNIQUE** `CREATE UNIQUE INDEX `idx_idempotency_keys_key` ON `idempotency_keys` (`endpoint`, `user`, `key`)`
- `CREATE INDEX `idx_idempotency_keys_expires` ON `idempotency_keys` (`expires_at`)`

### `aviary_stays` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `animal` | relation -> `animals` | yes | cascadeDelete=**true** |
| `aviary` | relation -> `aviaries` | yes | cascadeDelete=false |
| `started_at` | date |  |  |
| `ended_at` | date |  |  |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |

### `egg_records` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `animal` | relation -> `animals` | yes | cascadeDelete=**true** |
| `laid_at` | date |  |  |
| `count` | number | yes | min 1, int only |
| `fertility` | select |  | values: `unknown`, `fertile`, `infertile` |
| `fate` | select |  | values: `in_nest`, `dummy_swapped`, `removed`, `hatched`, `broken`, `discarded`, `unknown` |
| `attribution` | select |  | values: `confirmed`, `presumed` |
| `photos` | file |  | maxSelect=3; **PROTECTED** |
| `notes` | text |  | max 2000 |
| `author` | relation -> `users` |  | cascadeDelete=false |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |

### `medication_products` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `label` | text | yes | max 200 |
| `dose_unit` | text |  | max 50 |
| `dose_rate` | number |  | min 0 |
| `rate_min` | number |  | min 0 |
| `rate_max` | number |  | min 0 |
| `concentration_per_ml` | number |  | min 0 |
| `route` | relation -> `medication_routes` |  | cascadeDelete=false |
| `frequency_kind` | select |  | values: `once`, `scheduled`, `as_needed` |
| `interval_hours` | number |  | min 1 |
| `note` | text |  | max 2000 |
| `active` | bool |  |  |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |
| `cycle_on_days` | number |  | min 1, int only |
| `cycle_off_days` | number |  | min 1, int only |
| `cycle_repeats` | number |  | min 1, int only |

### `condition_labels` (view)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |
| `label` | json |  |  |
| `condition` | json |  |  |
| `case_count` | number |  | int only |

### `case_report_rows` (view)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |
| `case_number` | text |  | max 20 |
| `status` | select |  | values: `in_care`, `ready_for_release`, `disposed` |
| `admitted_at` | date |  |  |
| `found_at` | date |  |  |
| `city` | text |  | max 150 |
| `region` | text |  | max 150 |
| `species` | json |  |  |
| `name` | json |  |  |
| `outcome` | json |  |  |
| `ended_at` | json |  |  |
| `markings` | json |  |  |
| `reasons` | json |  |  |

### `vet_appointments` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `case` | relation -> `cases` | yes | cascadeDelete=**true** |
| `starts_at` | date | yes |  |
| `vet` | text |  | max 200 |
| `reason` | text |  | max 2000 |
| `outcome` | text |  | max 2000 |
| `attended_at` | date |  |  |
| `cancelled_at` | date |  |  |
| `reminder_lead_minutes` | number |  | min 1, int only |
| `reminder_muted` | bool |  |  |
| `created_by` | relation -> `users` |  | cascadeDelete=false |
| `org` | relation -> `organisations` |  | cascadeDelete=false |

### `audit_events` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |
| `action` | text | yes | max 64 |
| `actor_id` | text |  | max 32 |
| `actor_label` | text |  | max 200 |
| `actor_role` | text |  | max 32 |
| `actor_kind` | text |  | max 16 |
| `subject_collection` | text |  | max 64 |
| `subject_id` | text |  | max 32 |
| `subject_label` | text |  | max 200 |
| `case_id` | text |  | max 32 |
| `refs` | json |  |  |
| `changes` | json |  |  |
| `detail` | json |  |  |
| `severity` | text |  | max 16 |
| `ip` | text |  | max 64 |
| `user_agent` | text |  | max 512 |
| `request_id` | text |  | max 64 |
| `case_label` | text |  | max 64 |

Indexes:

- `CREATE INDEX `idx_audit_events_org_created` ON `audit_events` (`org`, `created`)`
- `CREATE INDEX `idx_audit_events_org_case` ON `audit_events` (`org`, `case_id`, `created`)`
- `CREATE INDEX `idx_audit_events_org_actor` ON `audit_events` (`org`, `actor_id`, `created`)`
- `CREATE INDEX `idx_audit_events_org_action` ON `audit_events` (`org`, `action`, `created`)`

### `case_carer_load` (view)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `carer` | relation -> `users` |  | cascadeDelete=false |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |
| `open_cases` | number |  | int only |

### `microscopy_finding_types` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `label` | text | yes | max 200 |
| `sample_types` | select |  | values: `crop_swab`, `fecal` |
| `description` | text |  | max 2000 |
| `active` | bool |  |  |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |

### `microscopy_samples` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `case` | relation -> `cases` | yes | cascadeDelete=**true** |
| `sample_type` | select | yes | values: `crop_swab`, `fecal` |
| `method` | select |  | values: `direct_smear`, `flotation` |
| `examined_at` | date |  |  |
| `examined_by` | select |  | values: `in_house`, `vet`, `lab` |
| `examiner` | relation -> `users` |  | cascadeDelete=false |
| `external_lab` | text |  | max 200 |
| `no_findings` | bool |  |  |
| `attachments` | file |  | maxSelect=5; **PROTECTED** |
| `notes` | text |  | max 2000 |
| `author` | relation -> `users` |  | cascadeDelete=false |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |

### `microscopy_findings` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `sample` | relation -> `microscopy_samples` | yes | cascadeDelete=**true** |
| `finding_type` | relation -> `microscopy_finding_types` |  | cascadeDelete=false |
| `free_text` | text |  | max 300 |
| `severity` | select | yes | values: `plus`, `plus_plus`, `plus_plus_plus` |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |

### `sponsorships` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `animal` | relation -> `animals` |  | cascadeDelete=false |
| `sponsor_name` | text | yes | max 200 |
| `sponsor_pronouns` | text |  | max 50 |
| `address` | text |  | max 300 |
| `postal_code` | text |  | max 20 |
| `city` | text |  | max 150 |
| `region` | text |  | max 150 |
| `mobile` | text |  | max 50 |
| `amount_cents` | number |  | min 0, int only |
| `interval` | select |  | values: `monthly`, `quarterly`, `yearly`, `one_time` |
| `started_at` | date |  |  |
| `ended_at` | date |  |  |
| `notes` | text |  | max 2000 |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |

Indexes:

- `CREATE INDEX `idx_sponsorships_animal` ON `sponsorships` (`animal`)`
- `CREATE INDEX `idx_sponsorships_org` ON `sponsorships` (`org`)`

### `vaccinations` (base)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `animal` | relation -> `animals` | yes | cascadeDelete=**true** |
| `vaccine` | text | yes | max 200 |
| `target` | text |  | max 200 |
| `administered_at` | date |  |  |
| `batch` | text |  | max 100 |
| `dose` | number |  |  |
| `dose_unit` | text |  | max 50 |
| `route` | relation -> `medication_routes` |  | cascadeDelete=false |
| `series` | select |  | values: `primary`, `booster` |
| `next_due_at` | date |  |  |
| `vet` | text |  | max 200 |
| `notes` | text |  | max 2000 |
| `attachments` | file |  | maxSelect=3; **PROTECTED** |
| `author` | relation -> `users` |  | cascadeDelete=false |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |

Indexes:

- `CREATE INDEX `idx_vaccinations_animal` ON `vaccinations` (`animal`)`
- `CREATE INDEX `idx_vaccinations_org_due` ON `vaccinations` (`org`, `next_due_at`)`

### `vaccine_labels` (view)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `org` | relation -> `organisations` | yes | cascadeDelete=false |
| `vaccine` | text | yes | max 200 |
| `target` | text |  | max 200 |
| `use_count` | number |  | int only |
| `last_used_at` | json |  |  |

### `medication_due` (view)

| Field | Type | Req | Notes |
| --- | --- | --- | --- |
| `case_id` | json |  |  |
| `org` | json |  |  |
| `active_carer` | json |  |  |
| `drug` | json |  |  |
| `dose` | json |  |  |
| `dose_unit` | json |  |  |
| `dose_rate` | json |  |  |
| `concentration_per_ml` | json |  |  |
| `route` | json |  |  |
| `frequency_kind` | json |  |  |
| `interval_hours` | json |  |  |
| `cycle_on_days` | json |  |  |
| `cycle_off_days` | json |  |  |
| `started_at` | json |  |  |
| `ended_at` | json |  |  |
| `next_due` | json |  |  |

## 3. The access-rule matrix (verbatim)

`NULL` means the rule is unset, i.e. **superuser-only** — no API caller can perform that action, only a hook, a migration, or the admin UI.

### `users`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **create**
  ```
  @request.context = "oauth2" || (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org)
  ```
- **update**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && (@request.auth.id = id || (@request.auth.role = "supervisor" && org = @request.auth.org)) && (@request.body.org:isset = false || @request.body.org = @request.auth.org)
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org
  ```
- **authRule** (can this identity log in at all)
  ```
  is_active = true
  ```
- **manageRule** — `NULL`
- **MFA rule** (when is a second factor demanded)
  ```
  mfa_enabled = true
  ```

### `organisations`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && id = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && id = @request.auth.org
  ```
- **create** — `NULL` (superuser only)
- **update**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && id = @request.auth.org
  ```
- **delete** — `NULL` (superuser only)

### `animals`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && (current_aviary = '' || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || current_aviary.keeper = @request.auth.id)
  ```
- **update**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || current_aviary.keeper = @request.auth.id || (cases_via_animal.active_carer ?= @request.auth.id && (cases_via_animal.status ?= "in_care" || cases_via_animal.status ?= "ready_for_release" || cases_via_animal.status ?= "")) || (cases_via_animal.case_shares_via_case.shared_with ?= @request.auth.id && cases_via_animal.case_shares_via_case.access ?= "edit" && (cases_via_animal.status ?= "in_care" || cases_via_animal.status ?= "ready_for_release" || cases_via_animal.status ?= "")))) && @request.body.org:isset = false && @request.body.current_aviary:isset = false && @request.body.lifetime_status:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org
  ```

### `finders`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || cases_via_finder.active_carer ?= @request.auth.id || cases_via_finder.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || cases_via_finder.active_carer ?= @request.auth.id || cases_via_finder.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **update**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || cases_via_finder.active_carer ?= @request.auth.id || (cases_via_finder.case_shares_via_case.shared_with ?= @request.auth.id && cases_via_finder.case_shares_via_case.access ?= "edit"))) && @request.body.org:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org
  ```

### `cases`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && (active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && (active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **create**
  ```
  ((@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && active_carer = @request.auth.id) && @request.body.finder:isset = false) && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || animal.current_aviary = '' || animal.current_aviary.keeper = @request.auth.id) && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || animal.lifetime_status != "deceased")
  ```
- **update**
  ```
  (((@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && (active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case_shares_via_case.shared_with ?= @request.auth.id && case_shares_via_case.access ?= "edit"))) && @request.body.org:isset = false) && @request.body.finder:isset = false) && @request.body.animal:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org
  ```

### `markings`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **create**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || animal.current_aviary.keeper = @request.auth.id || (animal.cases_via_animal.active_carer ?= @request.auth.id && (animal.cases_via_animal.status ?= "in_care" || animal.cases_via_animal.status ?= "ready_for_release" || animal.cases_via_animal.status ?= "")) || (animal.cases_via_animal.case_shares_via_case.shared_with ?= @request.auth.id && animal.cases_via_animal.case_shares_via_case.access ?= "edit" && (animal.cases_via_animal.status ?= "in_care" || animal.cases_via_animal.status ?= "ready_for_release" || animal.cases_via_animal.status ?= "")))) && (applied_in_case = '' || (applied_in_case.org = @request.auth.org && (applied_in_case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (applied_in_case.case_shares_via_case.shared_with ?= @request.auth.id && applied_in_case.case_shares_via_case.access ?= "edit"))))
  ```
- **update**
  ```
  (((@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || animal.current_aviary.keeper = @request.auth.id || (animal.cases_via_animal.active_carer ?= @request.auth.id && (animal.cases_via_animal.status ?= "in_care" || animal.cases_via_animal.status ?= "ready_for_release" || animal.cases_via_animal.status ?= "")) || (animal.cases_via_animal.case_shares_via_case.shared_with ?= @request.auth.id && animal.cases_via_animal.case_shares_via_case.access ?= "edit" && (animal.cases_via_animal.status ?= "in_care" || animal.cases_via_animal.status ?= "ready_for_release" || animal.cases_via_animal.status ?= "")))) && @request.body.org:isset = false) && @request.body.applied_in_case:isset = false) && @request.body.animal:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org
  ```

### `conditions`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org
  ```
- **update**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org) && @request.body.org:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org
  ```

### `case_conditions`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))
  ```
- **update**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))) && @request.body.case:isset = false && @request.body.org:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))
  ```

### `weights`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **create**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || animal.current_aviary.keeper = @request.auth.id || (animal.cases_via_animal.active_carer ?= @request.auth.id && (animal.cases_via_animal.status ?= "in_care" || animal.cases_via_animal.status ?= "ready_for_release" || animal.cases_via_animal.status ?= "")) || (animal.cases_via_animal.case_shares_via_case.shared_with ?= @request.auth.id && animal.cases_via_animal.case_shares_via_case.access ?= "edit" && (animal.cases_via_animal.status ?= "in_care" || animal.cases_via_animal.status ?= "ready_for_release" || animal.cases_via_animal.status ?= "")))) && (case = '' || (case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))))
  ```
- **update**
  ```
  (((@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || animal.current_aviary.keeper = @request.auth.id || (animal.cases_via_animal.active_carer ?= @request.auth.id && (animal.cases_via_animal.status ?= "in_care" || animal.cases_via_animal.status ?= "ready_for_release" || animal.cases_via_animal.status ?= "")) || (animal.cases_via_animal.case_shares_via_case.shared_with ?= @request.auth.id && animal.cases_via_animal.case_shares_via_case.access ?= "edit" && (animal.cases_via_animal.status ?= "in_care" || animal.cases_via_animal.status ?= "ready_for_release" || animal.cases_via_animal.status ?= "")))) && @request.body.org:isset = false) && @request.body.case:isset = false) && @request.body.animal:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && (@request.auth.role = "supervisor" || author = @request.auth.id) && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || animal.current_aviary.keeper = @request.auth.id || (animal.cases_via_animal.active_carer ?= @request.auth.id && (animal.cases_via_animal.status ?= "in_care" || animal.cases_via_animal.status ?= "ready_for_release" || animal.cases_via_animal.status ?= "")) || (animal.cases_via_animal.case_shares_via_case.shared_with ?= @request.auth.id && animal.cases_via_animal.case_shares_via_case.access ?= "edit" && (animal.cases_via_animal.status ?= "in_care" || animal.cases_via_animal.status ?= "ready_for_release" || animal.cases_via_animal.status ?= "")))
  ```

### `medications`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))
  ```
- **update**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))) && @request.body.case:isset = false && @request.body.org:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))
  ```

### `journal_entries`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && ((case != "" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case.case_shares_via_case.shared_with ?= @request.auth.id)) || (aviary != "" && aviary.org = @request.auth.org && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || aviary.keeper = @request.auth.id)))
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && ((case != "" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case.case_shares_via_case.shared_with ?= @request.auth.id)) || (aviary != "" && aviary.org = @request.auth.org && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || aviary.keeper = @request.auth.id)))
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && ((case != "" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))) || (aviary != "" && aviary.org = @request.auth.org && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || aviary.keeper = @request.auth.id)))
  ```
- **update**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && ((case != "" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))) || (aviary != "" && aviary.org = @request.auth.org && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || aviary.keeper = @request.auth.id)))) && @request.body.case:isset = false && @request.body.aviary:isset = false && @request.body.org:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && ((case != "" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))) || (aviary != "" && aviary.org = @request.auth.org && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || aviary.keeper = @request.auth.id)))
  ```

### `placements`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))
  ```
- **update**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))) && @request.body.case:isset = false && @request.body.org:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))
  ```

### `aviaries`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && (@request.auth.role = "coordinator" || @request.auth.role = "supervisor")
  ```
- **update**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || keeper = @request.auth.id)) && @request.body.org:isset = false && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || @request.body.keeper:isset = false || @request.body.keeper = @request.auth.id)
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org
  ```

### `dispositions`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))
  ```
- **update**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))) && @request.body.case:isset = false && @request.body.org:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))
  ```

### `case_shares`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && (shared_with = @request.auth.id || shared_by = @request.auth.id || case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor"))
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && (shared_with = @request.auth.id || shared_by = @request.auth.id || case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor"))
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && shared_by = @request.auth.id && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor")
  ```
- **update**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && (case.active_carer = @request.auth.id || shared_by = @request.auth.id || @request.auth.role = "supervisor")) && @request.body.case:isset = false && @request.body.shared_with:isset = false && @request.body.org:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && (case.active_carer = @request.auth.id || shared_by = @request.auth.id || @request.auth.role = "supervisor")
  ```

### `medication_administrations`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))
  ```
- **update**
  ```
  ((@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))) && @request.body.case:isset = false && @request.body.org:isset = false) && @request.body.medication:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))
  ```

### `case_summaries`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **create** — `NULL` (superuser only)
- **update** — `NULL` (superuser only)
- **delete** — `NULL` (superuser only)

### `case_activity`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **create** — `NULL` (superuser only)
- **update** — `NULL` (superuser only)
- **delete** — `NULL` (superuser only)

### `follow_ups`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))
  ```
- **update**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))) && @request.body.case:isset = false && @request.body.org:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))
  ```

### `exams`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))
  ```
- **update**
  ```
  ((@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))) && @request.body.case:isset = false && @request.body.org:isset = false) && @request.body.animal:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))
  ```

### `exam_findings`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && exam.case.org = @request.auth.org && (exam.case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || exam.case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && exam.case.org = @request.auth.org && (exam.case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || exam.case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && exam.case.org = @request.auth.org && (exam.case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (exam.case.case_shares_via_case.shared_with ?= @request.auth.id && exam.case.case_shares_via_case.access ?= "edit"))
  ```
- **update**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && exam.case.org = @request.auth.org && (exam.case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (exam.case.case_shares_via_case.shared_with ?= @request.auth.id && exam.case.case_shares_via_case.access ?= "edit"))) && @request.body.exam:isset = false && @request.body.org:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && exam.case.org = @request.auth.org && (exam.case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (exam.case.case_shares_via_case.shared_with ?= @request.auth.id && exam.case.case_shares_via_case.access ?= "edit"))
  ```

### `geocode_cache`

- **list** — `NULL` (superuser only)
- **view** — `NULL` (superuser only)
- **create** — `NULL` (superuser only)
- **update** — `NULL` (superuser only)
- **delete** — `NULL` (superuser only)

### `quarantine_records`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))
  ```
- **update**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))) && @request.body.case:isset = false && @request.body.org:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))
  ```

### `case_quarantine`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **create** — `NULL` (superuser only)
- **update** — `NULL` (superuser only)
- **delete** — `NULL` (superuser only)

### `admission_reasons`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org
  ```
- **update**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org) && @request.body.org:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org
  ```

### `marking_types`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org
  ```
- **update**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org) && @request.body.org:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org
  ```

### `medication_routes`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org
  ```
- **update**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org) && @request.body.org:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org
  ```

### `animal_species`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **create** — `NULL` (superuser only)
- **update** — `NULL` (superuser only)
- **delete** — `NULL` (superuser only)

### `idempotency_keys`

- **list** — `NULL` (superuser only)
- **view** — `NULL` (superuser only)
- **create** — `NULL` (superuser only)
- **update** — `NULL` (superuser only)
- **delete** — `NULL` (superuser only)

### `aviary_stays`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **create** — `NULL` (superuser only)
- **update** — `NULL` (superuser only)
- **delete** — `NULL` (superuser only)

### `egg_records`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || animal.current_aviary.keeper = @request.auth.id || (animal.cases_via_animal.active_carer ?= @request.auth.id && (animal.cases_via_animal.status ?= "in_care" || animal.cases_via_animal.status ?= "ready_for_release" || animal.cases_via_animal.status ?= "")) || (animal.cases_via_animal.case_shares_via_case.shared_with ?= @request.auth.id && animal.cases_via_animal.case_shares_via_case.access ?= "edit" && (animal.cases_via_animal.status ?= "in_care" || animal.cases_via_animal.status ?= "ready_for_release" || animal.cases_via_animal.status ?= "")))
  ```
- **update**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || animal.current_aviary.keeper = @request.auth.id || (animal.cases_via_animal.active_carer ?= @request.auth.id && (animal.cases_via_animal.status ?= "in_care" || animal.cases_via_animal.status ?= "ready_for_release" || animal.cases_via_animal.status ?= "")) || (animal.cases_via_animal.case_shares_via_case.shared_with ?= @request.auth.id && animal.cases_via_animal.case_shares_via_case.access ?= "edit" && (animal.cases_via_animal.status ?= "in_care" || animal.cases_via_animal.status ?= "ready_for_release" || animal.cases_via_animal.status ?= ""))) && @request.body.org:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && (@request.auth.role = "supervisor" || author = @request.auth.id) && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || animal.current_aviary.keeper = @request.auth.id || (animal.cases_via_animal.active_carer ?= @request.auth.id && (animal.cases_via_animal.status ?= "in_care" || animal.cases_via_animal.status ?= "ready_for_release" || animal.cases_via_animal.status ?= "")) || (animal.cases_via_animal.case_shares_via_case.shared_with ?= @request.auth.id && animal.cases_via_animal.case_shares_via_case.access ?= "edit" && (animal.cases_via_animal.status ?= "in_care" || animal.cases_via_animal.status ?= "ready_for_release" || animal.cases_via_animal.status ?= "")))
  ```

### `medication_products`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org
  ```
- **update**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org) && @request.body.org:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org
  ```

### `condition_labels`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && (condition != "" || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor"))
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && (condition != "" || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor"))
  ```
- **create** — `NULL` (superuser only)
- **update** — `NULL` (superuser only)
- **delete** — `NULL` (superuser only)

### `case_report_rows`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") && org = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") && org = @request.auth.org
  ```
- **create** — `NULL` (superuser only)
- **update** — `NULL` (superuser only)
- **delete** — `NULL` (superuser only)

### `vet_appointments`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))
  ```
- **update**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))) && @request.body.case:isset = false && @request.body.org:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))
  ```

### `audit_events`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org
  ```
- **create** — `NULL` (superuser only)
- **update** — `NULL` (superuser only)
- **delete** — `NULL` (superuser only)

### `case_carer_load`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") && org = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") && org = @request.auth.org
  ```
- **create** — `NULL` (superuser only)
- **update** — `NULL` (superuser only)
- **delete** — `NULL` (superuser only)

### `microscopy_finding_types`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org
  ```
- **update**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org && @request.body.org:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && @request.auth.role = "supervisor" && org = @request.auth.org
  ```

### `microscopy_samples`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))
  ```
- **update**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))) && @request.body.case:isset = false && @request.body.org:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && case.org = @request.auth.org && (case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (case.case_shares_via_case.shared_with ?= @request.auth.id && case.case_shares_via_case.access ?= "edit"))
  ```

### `microscopy_findings`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && sample.case.org = @request.auth.org && (sample.case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || sample.case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && sample.case.org = @request.auth.org && (sample.case.active_carer = @request.auth.id || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || sample.case.case_shares_via_case.shared_with ?= @request.auth.id)
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && sample.case.org = @request.auth.org && (sample.case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (sample.case.case_shares_via_case.shared_with ?= @request.auth.id && sample.case.case_shares_via_case.access ?= "edit"))
  ```
- **update**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && sample.case.org = @request.auth.org && (sample.case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (sample.case.case_shares_via_case.shared_with ?= @request.auth.id && sample.case.case_shares_via_case.access ?= "edit"))) && @request.body.sample:isset = false && @request.body.org:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && sample.case.org = @request.auth.org && (sample.case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (sample.case.case_shares_via_case.shared_with ?= @request.auth.id && sample.case.case_shares_via_case.access ?= "edit"))
  ```

### `sponsorships`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || animal.current_aviary.keeper = @request.auth.id)
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || animal.current_aviary.keeper = @request.auth.id)
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **update**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || animal.current_aviary.keeper = @request.auth.id)) && @request.body.animal:isset = false && @request.body.org:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || animal.current_aviary.keeper = @request.auth.id)
  ```

### `vaccinations`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **create**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || animal.current_aviary.keeper = @request.auth.id || (animal.cases_via_animal.active_carer ?= @request.auth.id && (animal.cases_via_animal.status ?= "in_care" || animal.cases_via_animal.status ?= "ready_for_release" || animal.cases_via_animal.status ?= "")) || (animal.cases_via_animal.case_shares_via_case.shared_with ?= @request.auth.id && animal.cases_via_animal.case_shares_via_case.access ?= "edit" && (animal.cases_via_animal.status ?= "in_care" || animal.cases_via_animal.status ?= "ready_for_release" || animal.cases_via_animal.status ?= "")))
  ```
- **update**
  ```
  (@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || animal.current_aviary.keeper = @request.auth.id || (animal.cases_via_animal.active_carer ?= @request.auth.id && (animal.cases_via_animal.status ?= "in_care" || animal.cases_via_animal.status ?= "ready_for_release" || animal.cases_via_animal.status ?= "")) || (animal.cases_via_animal.case_shares_via_case.shared_with ?= @request.auth.id && animal.cases_via_animal.case_shares_via_case.access ?= "edit" && (animal.cases_via_animal.status ?= "in_care" || animal.cases_via_animal.status ?= "ready_for_release" || animal.cases_via_animal.status ?= "")))) && @request.body.org:isset = false && @request.body.animal:isset = false
  ```
- **delete**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && (@request.auth.role = "supervisor" || author = @request.auth.id) && ((@request.auth.role = "coordinator" || @request.auth.role = "supervisor") || animal.current_aviary.keeper = @request.auth.id || (animal.cases_via_animal.active_carer ?= @request.auth.id && (animal.cases_via_animal.status ?= "in_care" || animal.cases_via_animal.status ?= "ready_for_release" || animal.cases_via_animal.status ?= "")) || (animal.cases_via_animal.case_shares_via_case.shared_with ?= @request.auth.id && animal.cases_via_animal.case_shares_via_case.access ?= "edit" && (animal.cases_via_animal.status ?= "in_care" || animal.cases_via_animal.status ?= "ready_for_release" || animal.cases_via_animal.status ?= "")))
  ```

### `vaccine_labels`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org
  ```
- **create** — `NULL` (superuser only)
- **update** — `NULL` (superuser only)
- **delete** — `NULL` (superuser only)

### `medication_due`

- **list**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && active_carer = @request.auth.id
  ```
- **view**
  ```
  @request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest" && org = @request.auth.org && active_carer = @request.auth.id
  ```
- **create** — `NULL` (superuser only)
- **update** — `NULL` (superuser only)
- **delete** — `NULL` (superuser only)

## 4. Patterns in the rules

These are the reusable principles the 175 non-null rule strings above are
assembled from (44 collections x 5 verbs = 220 slots, 45 of them `NULL`).
Each rule in section 3 is a conjunction of a handful of these clauses, and
almost every rule can be read as *preamble AND tenant AND reach AND
immutability*.

### 4.1 The four-clause shape

Read any rule as:

```
<identity preamble> && <tenant clause> && <reach clause> && <immutability guards>
```

- **identity preamble** — always present, always identical.
- **tenant clause** — always present, one of four shapes (§4.2).
- **reach clause** — present on everything except org-wide-readable reference
  data; expresses *which* rows inside the tenant (§4.4–4.6).
- **immutability guards** — update rules only, plus two create rules (§4.7).

### 4.2 Identity is checked three ways, every time

Every non-null rule in the entire schema opens with the same three tests:

```
@request.auth.id != "" && @request.auth.is_active = true && @request.auth.role != "guest"
```

Three independent principles, not one:

- **Authenticated.** No collection has any anonymous access. There is no public
  read anywhere, not even on reference code lists.
- **Not deactivated.** `is_active` is *also* the auth collection's `authRule`
  (`is_active = true`), so a deactivated user cannot mint a new token. Repeating
  it in every rule is what makes deactivation take effect *immediately* for
  tokens already issued, rather than at token expiry. Deactivation is therefore
  the real revocation mechanism — it does not depend on token lifetime.
- **Not a guest.** The `guest` role is excluded from every single collection
  rule in the schema. A guest can authenticate (the `authRule` does not exclude
  them) and will receive their own record in the auth response, but they can
  neither list nor read nor write *anything*. `guest` is a token with no data
  attached. The one rule where `role != "guest"` is absent is
  `users.updateRule`, because that path is scoped to `@request.auth.id = id`
  (self-service profile edit) and a guest editing their own name is harmless.

### 4.3 Org scoping is a property of the row, never of the request

Tenancy is always expressed by comparing a *stored* relation against
`@request.auth.org` — never by filtering on something the client sent, and never
via an `@collection.*` lookup. Four shapes, in order of distance:

| Shape | Expression | Used by |
| --- | --- | --- |
| Self | `id = @request.auth.org` | `organisations` |
| Own field | `org = @request.auth.org` | `animals`, `finders`, `cases`, `markings`, `weights`, `aviaries`, `case_shares`, `egg_records`, `sponsorships`, `vaccinations`, `audit_events`, `aviary_stays`, all code lists, all views |
| Via parent case | `case.org = @request.auth.org` | `case_conditions`, `medications`, `placements`, `dispositions`, `medication_administrations`, `follow_ups`, `exams`, `quarantine_records`, `vet_appointments`, `microscopy_samples` |
| Two hops | `exam.case.org = @request.auth.org`, `sample.case.org = @request.auth.org` | `exam_findings`, `microscopy_findings` |

The consequence: a child row's tenant is *derived*, not stored redundantly for
authorisation purposes — even where an `org` column also exists. Note that
`exams`, `exam_findings`, `follow_ups` and `vet_appointments` have a
**non-required** `org` field precisely because the rule never reads it; the
parent case carries the authoritative one.

Because the traversal reads the stored parent, moving a row between tenants can
only be prevented by forbidding the write, which is §4.7.

### 4.4 Role checks are literal string comparisons, in exactly two idioms

There is no role hierarchy, no bitmask, no `~` matching. Two spellings recur:

- **Elevated** — `(@request.auth.role = "coordinator" || @request.auth.role = "supervisor")`
- **Admin** — `@request.auth.role = "supervisor"`

`carer` is never named positively; it is the default that falls through to the
ownership clauses. Note also that the admin idiom is always written as
`@request.auth.role != "guest" && @request.auth.role = "supervisor"` — the guest
test is redundant there, an artefact of a shared preamble, and harmless.

**The important asymmetry: coordinator is a READ role, not a WRITE role.** On
every case-child collection, the *read* rules admit `(coordinator || supervisor)`
but the *write* rules admit only:

```
case.active_carer = @request.auth.id || @request.auth.role = "supervisor" || (edit share)
```

Coordinator is absent from that list. So a coordinator sees every case in the org
but cannot edit a case they do not carry; only a supervisor can write anywhere.
Coordinator *is* a write role for two other things: org-level structure
(`aviaries.createRule` is elevated-only) and animal-level records (§4.6, where
the elevated idiom appears in create/update). Read that as: coordinators arrange
the shelter and its birds; supervisors alone may reach into a colleague's case.

### 4.5 There are exactly three ways to reach a case

Every case-scoped rule offers the same disjunction:

```
active_carer = @request.auth.id || (coordinator || supervisor) || case_shares_via_case.shared_with ?= @request.auth.id
```

1. **You are the active carer** — the primary ownership edge.
2. **You hold an elevated role** (read only, per §4.4).
3. **A `case_shares` row names you** — the delegation primitive.

For **reads**, any share grants access regardless of its `access` value. For
**writes**, the share must additionally be an edit share:

```
case_shares_via_case.shared_with ?= @request.auth.id && case_shares_via_case.access ?= "edit"
```

Sharing is itself constrained: `case_shares.createRule` requires
`shared_by = @request.auth.id` *and* `(case.active_carer = @request.auth.id || @request.auth.role = "supervisor")`
— you may only delegate a case you actually carry, and you may not forge who did
the sharing. `shared_with` is frozen after creation, and a unique index on
`(case, shared_with)` prevents a second, contradictory grant to the same person.

### 4.6 Animal-level writes use a wider custody predicate with an open-case gate

Records that hang off an *animal* rather than a case (`animals`, `markings`,
`weights`, `egg_records`, `vaccinations`) share one long custody clause:

```
(coordinator || supervisor)
  || animal.current_aviary.keeper = @request.auth.id
  || (animal.cases_via_animal.active_carer ?= @request.auth.id
      && (animal.cases_via_animal.status ?= "in_care"
          || animal.cases_via_animal.status ?= "ready_for_release"
          || animal.cases_via_animal.status ?= ""))
  || (edit share on such a case, with the same status gate)
```

Three principles are packed in here:

- **Aviary keepership is a second ownership edge, parallel to carership.**
  `aviaries.keeper` is a *required* field, so every aviary always has exactly one
  responsible user, and that user gains write access to every animal currently in
  it — plus its journal (`journal_entries` discriminates on
  `aviary != ""` and checks `aviary.keeper`).
- **Write access expires when the case closes.** The status gate is the closing
  mechanism: once a carer's case reaches `disposed`, the carer stops being able
  to write to the animal. Read access is unaffected (the read rules are plain
  org-wide), so history stays visible but becomes append-only-by-others. This is
  the only place in the schema where authorisation depends on a *state machine
  value* rather than on identity.
- **A missing status counts as open** (`status ?= ""`). The fail-safe direction is
  chosen deliberately and consistently — the same choice appears in
  `case_carer_load`'s SQL and in the user-deletion guard hook.

`cases.createRule` mirrors this from the other side: you may not open a case on
an animal in somebody else's aviary
(`animal.current_aviary = '' || animal.current_aviary.keeper = @request.auth.id`)
and you may not open a case on a dead bird
(`animal.lifetime_status != "deceased"`) — both unless elevated.

Where a record can be attached to *both* an animal and a case (`markings`,
`weights`), the create rule requires **both** predicates: animal custody *and*
(the case is empty **or** the case is reachable-for-write). Neither edge alone is
enough to file a record against a case you cannot edit.

### 4.7 `:isset = false` is the schema's only field-level write guard, used for three jobs

The idiom `@request.body.<field>:isset = false` occurs 60 times across the
schema, and every occurrence is one of three distinct jobs. By field:
`org` ×30, `case` ×13, `animal` ×6, `finder` ×2, and one each of
`shared_with`, `sample`, `medication`, `lifetime_status`, `keeper`, `exam`,
`current_aviary`, `aviary`, `applied_in_case`.

**(a) Tenant pinning.** `@request.body.org:isset = false` is on essentially every
`updateRule` in the schema. Once written, a row can never be moved to another
organisation through the API. This closes the hole §4.3 leaves open: since the
tenant clause reads the *stored* org, an update that changed org would be
authorised against the old tenant and land in the new one.

**(b) Parent freezing — this is what makes parent-derived access sound.** The
guards `case:isset = false`, `animal:isset = false`, `exam:isset = false`,
`sample:isset = false`, `medication:isset = false`, `aviary:isset = false`,
`applied_in_case:isset = false`, `shared_with:isset = false` are not tidiness.
Because an update rule evaluates the parent traversal against the stored record,
a re-parenting write would be checked against a parent the caller *can* reach and
then persisted under one they cannot. Freezing the relation is the actual
mitigation for that escalation path. Rule of thumb: **if a collection derives its
authorisation from a relation, that relation is immutable.**

**(c) Field-level privilege splits.** Three shapes:

- *Never client-writable at all*: `animals.updateRule` carries
  `@request.body.current_aviary:isset = false && @request.body.lifetime_status:isset = false`.
  Both fields are derived server-side; no API caller of any role may set them.
- *Conditional* — `aviaries.updateRule` ends with
  `((coordinator || supervisor) || @request.body.keeper:isset = false || @request.body.keeper = @request.auth.id)`.
  A keeper may edit their own aviary but may not hand it to somebody else;
  reassignment is a coordinator act. Note the middle arm: leaving `keeper`
  unmentioned is also fine.
- *Permissive variant* — `users.updateRule` uses
  `(@request.body.org:isset = false || @request.body.org = @request.auth.org)`
  rather than a hard freeze, because the self-service and OAuth2 update paths
  legitimately echo the whole record back. Same for `cases.updateRule`'s
  sibling guards, which are hard freezes on `finder` and `animal`.

The one guard used on **create**: `cases.createRule` contains
`@request.body.finder:isset = false`. A case may not be created with a finder
attached — the finder link is made afterwards by the intake route, so that PII
never travels on the case-creation request.

### 4.8 A parent relation grants access to its children; deletion does not follow the same rule

Child collections carry no ownership fields of their own. `case_conditions`,
`medications`, `placements`, `dispositions`, `medication_administrations`,
`follow_ups`, `exams`, `quarantine_records`, `vet_appointments` and
`microscopy_samples` all read `case.*`; `exam_findings` reads `exam.case.*`;
`microscopy_findings` reads `sample.case.*`. Two consequences worth stating:

- **A child is exactly as reachable as its parent** — there is no case where a
  child is more or less visible than the case it belongs to. Authorisation is a
  single tree rooted at `cases` (and a second one rooted at `animals`).
- **Child deletion is as permissive as child editing.** On every case child,
  `deleteRule` is byte-identical to `createRule`: whoever may add a row may
  remove it. That is the opposite of the top-level convention (§4.9), and it is
  deliberate — correcting a mistyped dose is a carer act, deleting a case is not.

### 4.9 Deleting a top-level entity is a supervisor act

For every top-level record — `animals`, `finders`, `cases`, `markings`,
`conditions`, `aviaries`, `medication_products`, `microscopy_finding_types` and
all four code lists — `deleteRule` is exactly the supervisor+org rule and nothing
else. Three principled exceptions:

- **"Supervisor or my own row"** on `weights`, `egg_records`, `vaccinations`:
  `(@request.auth.role = "supervisor" || author = @request.auth.id)` **and** the
  full §4.6 custody predicate. You may retract a measurement you personally
  recorded, while you still have custody. (The `author` field is set
  server-side — §4.11.)
- **`case_shares`**: the carer, the original sharer, or a supervisor may revoke a
  grant.
- **`organisations`**: `deleteRule` and `createRule` are both `NULL`. A tenant can
  only be created or destroyed out-of-band.

### 4.10 PII-bearing collections are read-gated below the org line

Everywhere else in the schema, *reading* is org-wide: any non-guest member of the
organisation may list `animals`, `cases` metadata, code lists, weights,
vaccinations. The two collections holding personal data of **non-users** break
that pattern, and they are the only ones that do:

- **`finders`** (finder name, phone, alt phone, email, address, postal code,
  city) — list/view additionally require
  `((coordinator || supervisor) || cases_via_finder.active_carer ?= @request.auth.id || cases_via_finder.case_shares_via_case.shared_with ?= @request.auth.id)`.
  You may see a finder's contact details only if you hold a case that points at
  them, or you hold an elevated role.
- **`sponsorships`** (donor name, pronouns, address, mobile, amount) — list/view
  require `((coordinator || supervisor) || animal.current_aviary.keeper = @request.auth.id)`.
  Carership grants nothing here; only elevated roles and the keeper of the
  sponsored bird's aviary may read a donor record.

Both have a `createRule` of bare org-membership, but they mean different things
by it:

- **`finders` genuinely is write-wider-than-read.** Anybody in the org may record
  a finder — you cannot take an intake call otherwise — but not read back the
  ones they are not responsible for. Treat "create broader than view" as the
  intended shape for PII intake here, not as an oversight.
- **`sponsorships` only *looks* write-wide.** `pb_hooks/sponsorships.pb.js`
  narrows create to what the rule cannot express (a two-hop check against the
  incoming body): the animal must currently be in an enclosure, and the writer
  must *keep* that enclosure — using the narrow `lib_custody.keeps()` rather than
  `holds()`, deliberately, because `holds()` would also admit an open case's
  carer, who is **not** a reader of the patronage. Admitting them would create a
  write-only door into another keeper's PII view. Coordinators and supervisors
  override the keepership arm but not the "must be in an enclosure" arm.

`finders` additionally carries a `pii_purged` boolean, i.e. retention is modelled
in the schema — see §5.11 for why that field is not as safe as it looks.

### 4.11 Views are read-only by construction, and their rules are the whole guard

All 9 views have `createRule = updateRule = deleteRule = NULL`; PocketBase views
are not writable regardless. Their SQL runs with full privileges, so the
list/view rule is the *only* thing standing between a caller and the joined data.
Accordingly the views split into three tiers:

- **Plain org-wide** — `case_summaries`, `case_activity`, `case_quarantine`,
  `animal_species`, `vaccine_labels`. Aggregate metadata, no clinical narrative.
- **Elevated-only** — `case_report_rows` and `case_carer_load` insert
  `(@request.auth.role = "coordinator" || @request.auth.role = "supervisor")`
  into an otherwise plain org rule. Cross-case aggregation is an oversight
  capability: `case_report_rows` flattens species, outcome, marking history and
  admission reasons into one row per case, and `case_carer_load` exposes every
  colleague's open-case count.
- **Narrower than org** — `medication_due` requires
  `active_carer = @request.auth.id`. Your own dosing schedule only; a supervisor
  querying this view sees nothing but their own. Whoever needs the org-wide
  picture must go through `medications`.

And one genuinely subtle one: `condition_labels` uses
`(condition != "" || (@request.auth.role = "coordinator" || @request.auth.role = "supervisor"))`.
A label derived from the shared `conditions` code list is visible to everyone; a
label derived from somebody's `free_text` diagnosis is elevated-only — because
free text can carry clinical narrative that the code list cannot.

### 4.12 Null rules mark the server-only surface

`NULL` is used as a deliberate access class, not as an oversight. Four groups:

- **Fully opaque** (all five rules null) — `geocode_cache`, `idempotency_keys`.
  Infrastructure. No client has any access, read or write, ever.
- **Append-only, supervisor-readable** — `audit_events` has supervisor+org
  list/view and null create/update/delete. Nobody with an API token can write,
  amend or erase an audit record; the log is written by hooks and is immutable
  from outside. (Hook writes use model-level events, which bypass rules.)
- **Derived, readable** — `aviary_stays` has org-wide list/view and null writes.
  The occupancy history is computed by a hook from the animal record, so animal
  and stay can never disagree.
- **Views** — as §4.11.

Reading a null create/update pair as "hook-only" is load-bearing elsewhere: the
cross-tenant relation hook (`lib_org_scope.js`) *derives* its own skip list from
exactly that condition, so a new hook-only collection is excluded automatically.

### 4.13 What the rules deliberately do NOT do (and hooks do instead)

Three classes of invariant are absent from the rules on purpose, and knowing
which is essential to reading the model correctly:

- **Cross-tenant relation targets.** No rule checks that an *incoming* relation
  points inside your org, because an update rule's field reference resolves
  against the stored record and would validate the old target. `org_scope.pb.js`
  / `lib_org_scope.js` do it on model create/update, driven off the live schema
  (every relation whose target collection has an `org`), so a collection added
  later is covered without anyone updating a list.
- **Privilege escalation on `users`.** See §5.1 — this is the most important
  hook-enforced invariant in the system.
- **Server-set provenance.** `author`, `created_by`, `admitted_by`,
  `administered_by`, `examiner`, `applied_by`, `performed_by`, `set_by` and
  `shared_by` are ordinary writable fields as far as the rules are concerned;
  `authorship.pb.js` is what makes them trustworthy (§5.4).
  `case_shares.shared_by` is the one that is *also* rule-enforced
  (`shared_by = @request.auth.id` in the create rule).

### 4.14 Custom routes are a parallel authorisation surface

Roughly a dozen routes under `/api/federfall/…` write with `tx.save()` /
`$app.save()`, which fires **no request hook and consults no collection rule**.
They re-implement the model by hand, and `pb_hooks/lib_auth.js` supplies the
three gates that mirror §4.2/§4.4 exactly:

| Gate | Asserts | Used by |
| --- | --- | --- |
| `requireMember` | `is_active && role !== "guest"` + non-empty `org` | intake, exam, microscopy, the three batch routes, case report PDF |
| `requireReporting` | `is_active && (coordinator \|\| supervisor)` | `/reports/annual`, `/stats` — anything org-wide by construction, so a carer cannot obtain the org roster through a route |
| `requireSupervisor` | `is_active && role === "supervisor"` | `/merge-animals` |

Two principles worth carrying forward. First, `$apis.requireAuth()` alone is
never sufficient — it proves a token exists and says nothing about `is_active`,
`guest` or `org`; the `/geocode` routes therefore carry their own explicit guest
rejection. Second, the rule-level guest wall is **not** inherited by routes, and
`tests/test_rules.py`'s guest sweep walks *collections* — a route that forgets
`role !== "guest"` passes the test suite. Beyond the gate, each write route
re-derives its own reach check: the batch and exam/microscopy routes use an
inline equivalent of §4.5 (`case.org` + active carer ∥ supervisor ∥ edit share),
while `/vaccinate-batch` uses the animal-custody predicate of §4.6
(`lib_custody.holds`) because it writes animal-scoped rows.

## 5. Security-critical and non-obvious

Ordered roughly by how much damage a misunderstanding would do.

### 5.1 `users.updateRule` is intentionally permissive and depends on a hook

```
@request.auth.id != "" && @request.auth.is_active = true
  && (@request.auth.id = id || (@request.auth.role = "supervisor" && org = @request.auth.org))
  && (@request.body.org:isset = false || @request.body.org = @request.auth.org)
```

Read literally, **this rule lets a carer send `{"role": "supervisor"}` for their
own record.** There is no `@request.body.role` guard, no `is_active` guard and no
`verified` guard in the rule. The block lives in
`pb_hooks/main.pb.js` (section 5 of that file), an `onRecordUpdateRequest` hook
on `users` that compares the incoming record against `original()` and throws
`ForbiddenError` if a non-supervisor changed any of
`["role", "org", "is_active", "verified"]`.

This is the single most important thing to know about the model: **the rules
alone do not prevent privilege escalation.** Any refactor that drops or reorders
that hook, or any code path that writes a user record via a model-level event
rather than a request event, reopens it. It is also why `role != "guest"` is
absent from this one rule — the rule is deliberately widened to self and the
narrowing happens in the hook.

The same hook file adds two availability invariants the rules cannot express: an
org may never lose its **last active supervisor** (by demotion, deactivation,
org move or deletion), and a user who is the **active carer of an open case**
cannot be deleted. Both are enforced on the request path only.

### 5.2 Cascade deletes concentrate destructive power in the supervisor role

`cascadeDelete=true` relations, all pointing at `animals` or `cases` (or `users`
for shares):

| Child | Parent | Effect of deleting the parent |
| --- | --- | --- |
| `cases.animal` | `animals` | every admission of that bird disappears |
| `markings.animal`, `weights.animal`, `egg_records.animal`, `vaccinations.animal`, `aviary_stays.animal`, `exams.animal` | `animals` | the bird's entire clinical history |
| `case_conditions.case`, `medications.case`, `journal_entries.case`, `placements.case`, `dispositions.case`, `medication_administrations.case`, `follow_ups.case`, `exams.case`, `quarantine_records.case`, `vet_appointments.case`, `microscopy_samples.case`, `case_shares.case` | `cases` | everything under the case |
| `exam_findings.exam` | `exams` | findings |
| `microscopy_findings.sample` | `microscopy_samples` | findings |
| `journal_entries.aviary` | `aviaries` | **the aviary's journal is deleted with the aviary** |
| `case_shares.shared_with`, `idempotency_keys.user` | `users` | deleting a user silently revokes every share granted to them |

Since `animals.deleteRule` and `cases.deleteRule` are supervisor-only, a single
supervisor call can erase an arbitrary depth of clinical record with no
tombstone anywhere except `audit_events`. Two relations are pointedly
**non**-cascading and worth noticing as decisions rather than omissions:

- **`sponsorships.animal` is `cascadeDelete=false`** while every other
  animal-pointing relation cascades. A donation record deliberately outlives the
  bird it sponsored.
- **`cases.active_carer` and `cases.admitted_by` are `cascadeDelete=false`** —
  deleting a user must not delete their cases, which is exactly why the
  open-caseload guard in §5.1 exists.

### 5.3 Two fields no API caller may ever write

`animals.updateRule` ends with:

```
&& @request.body.org:isset = false && @request.body.current_aviary:isset = false && @request.body.lifetime_status:isset = false
```

`current_aviary` and `lifetime_status` are **not writable by any role, including
supervisor**, through the ordinary record API. They are derived server-side (the
aviary-stay and disposition hooks own them). A client that sends either field —
even with the correct value, even as a supervisor — gets a 403. This is the most
common way to be surprised by this schema.

`cases.finder` is the same idea across both verbs: `:isset = false` on create
*and* on update. The finder link is only ever established by the intake route.

### 5.4 `guest` is a login with zero data access

The auth collection's `authRule` is `is_active = true` — it does **not** exclude
guests. A guest can therefore authenticate successfully, receive a token, and
receive their own user record in the auth response, while every collection rule
in the schema excludes them. Anything that treats "authentication succeeded" as
"this user can use the app" will produce a session that 403s on every request.
`medication_due` was given its own guest exclusion in a dedicated migration
(`1700000092_medication_due_guest_wall.js`), which suggests this was learned the
hard way once.

### 5.5 The OAuth2 create path is an unauthenticated write

```
users.createRule = @request.context = "oauth2" || (… supervisor … )
```

The first arm has **no other condition at all** — during an OAuth2 sign-in flow,
PocketBase may create a `users` row with no authenticated caller. Everything
about the resulting row's `org`, `role` and `is_active` is therefore decided
entirely by `oauth2_provisioning.pb.js`, not by the rule. The rule's job is only
to permit the mechanism. Any org/role defaulting logic in that hook is
security-relevant, and a failure there means self-provisioning into a tenant.
(`FEDERFALL_OIDC_CARER_GROUP` in the test harness shows role is mapped from an
IdP group claim.)

### 5.6 Protected file fields inherit the VIEW rule, and two paths sidestep it

Every clinical media field is `protected: true` — `animals.photo`,
`cases.intake_photos`, `journal_entries.attachments`, `egg_records.photos`,
`microscopy_samples.attachments`, `vaccinations.attachments`. Without it
PocketBase serves file fields publicly by full URL, with the random filename
suffix as the only guard. Protected files instead require a short-lived
(~2 minute) token from `POST /api/files/token`, and the token is only usable for
records the holder can read — so blob access transitively inherits the owning
collection's **view** rule. There is no custom hook on the token or download
path; the record rule is the whole story.

Two consequences to keep in mind:

- It inherits the *view* rule, which on `animals`, `egg_records` and
  `vaccinations` is plain org-wide. Photographs there are visible to every
  non-guest member of the org even though the *write* side is tightly
  custody-scoped.
- **Two paths bypass the token entirely, both deliberately.** `intake.pb.js`
  copies `intake_photos[0]` onto `animals.photo` when that field is empty,
  widening one case-scoped intake photo — which may show the finder's hands or
  home — to org-wide readability. And `case_report.pb.js` reads blobs
  server-side via `newFilesystem()` and embeds them in the PDF, so the report
  route's own case-view check is the only gate on those images.

Defence in depth: `web_headers.pb.js` sends
`Content-Security-Policy: default-src 'none'; sandbox` plus
`X-Content-Type-Options: nosniff` on every `/api/files/…` response, so a file
that slips past the MIME allowlist still cannot run script against the app
origin.

### 5.7 Unique indexes that carry meaning

- `cases (org, case_number)` **UNIQUE** — case numbers are unique per tenant, not
  globally. Two orgs may both have case `2024-001`.
- `case_shares (case, shared_with)` **UNIQUE** — you cannot hold two
  contradictory grants on the same case; a re-share must update the existing row
  (and `shared_with` is frozen, so it must be deleted and recreated).
- `users (email)` **UNIQUE** `WHERE email != ''` — global, i.e. **across
  tenants**. One email address cannot be a member of two organisations.
- `geocode_cache (kind, cache_key)` and `idempotency_keys (endpoint, user, key)`
  — the correctness guarantee of the cache and of replay protection.

### 5.8 Rules that are stricter than they look

- **`medication_due` excludes supervisors.** `active_carer = @request.auth.id`,
  with no elevated escape hatch. A supervisor cannot use this view to see the
  org's dosing schedule.
- **`condition_labels` hides free-text diagnoses from carers.**
  `(condition != "" || elevated)` — the arm that looks like a null-check is an
  access decision.
- **`organisations` cannot be created or deleted by anyone**, and can be updated
  only by a supervisor of that same org (`id = @request.auth.org`). There is no
  cross-org administration surface in the API at all; a superuser is required.
- **`cases.createRule` refuses to open a case on a `deceased` animal** and on an
  animal in another keeper's aviary, unless the caller is elevated. An intake
  flow that hits a 403 here is usually looking at a stale `lifetime_status`.
- **Animal-level write access expires with the case.** §4.6. A carer who could
  add a weight yesterday cannot today if the case was disposed overnight, and
  the resulting 403 has nothing to do with their role.

### 5.9 Collections whose org column is decorative

`exams.org`, `exam_findings.org`, `follow_ups.org` and `vet_appointments.org` are
**not required**, and no rule reads them — the tenant is taken from the parent
case. `lib_org_scope.js` handles this explicitly by falling back to the parent
case's org so the cross-tenant check cannot be dodged by simply omitting the
field. Do not rely on those columns being populated.

### 5.10 The cross-tenant relation check is a hook, and its own docs say it is low-value

`lib_org_scope.js` blocks any relation naming a row in another organisation. Its
header is explicit that the realisable impact was small — because every access
rule also compares org, a foreign user set as `active_carer` still cannot read
the case, so the leak was cross-tenant *vocabulary* (an expanded
`case_conditions.condition` label) rather than clinical data. The one case that
mattered was `cases.animal`: with `cascadeDelete=true`, pointing a case at
another org's bird meant deleting that bird destroyed a foreign org's clinical
history. That is the mechanism to keep in mind whenever a new cascading relation
is added.

### 5.11 `finders.pii_purged` is a retention marker, not a permission — and it is client-writable

The daily `finderPiiRetention` cron erases
`[first_name, last_name, organisation, phone, alt_phone, email, notes]` to `""`
and sets `pii_purged = true` once every case of that finder is `disposed` and the
retention window (`organisations.settings.finderRetentionMonths`, default 24) has
elapsed. Location fields (address, postal code, city, region) are **deliberately
kept** as non-identifying "where do birds come from" data. A finder with zero
referencing cases is deleted outright after a 24h grace, ignoring the window.

Two things about this are security-relevant:

- **`pii_purged` has no `:isset` guard and no hook pin.** `finders.updateRule`
  lets any carer who reaches the finder set it to `true`, which permanently
  exempts that finder from the scrub — the cron only considers
  `pii_purged = false`. This is the one client-writable retention control in the
  schema.
- **The reference date is `disposition.created`, not `disposed_at`** — chosen
  precisely because `disposed_at` is client-writable and could be backdated to
  pull the scrub forward or push it out.

Note the mirror-image treatment of `sponsorships`: an *ended* patronage on a
living bird is kept forever, PII included, because a German donation receipt
(§147 AO / §257 HGB) is worthless without name and address. Only orphaned
sponsorships (dangling `animal`) are deleted. Where finder identity must be
destroyed, donor identity must be preserved.

Audit interacts with both: `lib_audit.js` redacts these fields to
`{field, redacted: true}`, hard-returns `""` for any `finders`/`sponsorships`
subject label, and — the stated reason — `audit_events` is append-only, so
anything logged there **outlives every scrub**. `sponsorships` redaction is
broader than `finders`: it covers the location fields too, since "a postal code
beside a name is an identification".

### 5.12 `case_status.pb.js` closes a real, verified privilege escalation

`cases.status` looks like ordinary data, but §4.6 makes animal write access
depend on it, and `cases.active_carer` **never expires**. Before the hook, a
carer of a case closed years ago could `PATCH {"status": "in_care"}` on their own
old case and thereby re-acquire write custody of a bird now in somebody else's
care. Nothing in the rules prevents it — `cases.updateRule` admits the active
carer and carries no status guard.

`case_status.pb.js` therefore refuses: creating a case as `disposed`; setting
`status != "disposed"` while any disposition exists ("delete the outcome to
re-open it"); and setting `disposed` with no disposition. `in_care ↔
ready_for_release` stays free. Related: `disposition_dates.pb.js` refuses a
`disposed_at` more than 24h in the future, because that field is the ordering key
for `lifetime_status` and `current_aviary` — a row dated 2099 would permanently
own custody of the bird.

**Read this as the general shape:** where authorisation depends on a state
machine value, the state machine's transitions are themselves an access control,
and they live in hooks.

### 5.13 `audit_events` is append-only against superusers too

`pb_hooks/audit.pb.js` registers **model** hooks, not request hooks, so the
guards apply to the Admin UI and to superuser API calls — which collection rules
never do:

- `onRecordUpdate` throws unconditionally: `"audit_events is append-only."` No
  carve-out for any caller.
- `onRecordDelete` derives permission from the **row's own age**, not from who is
  asking: deletable only when `created < now − audit_retention_days` (org
  setting, default 730; `0` means keep forever, i.e. nothing is ever deletable).
  An unparseable `created` is refused. The retention cron uses exactly this and
  nothing more, so a bug degrades to "nothing was purged" and never to "history
  was quietly rewritten". There is deliberately no "I am the purger" flag,
  because JSVM module state is per-VM and a settable flag would be settable from
  another hook.

The collection also holds **no relations** — the actor is stored as `actor_id`
text — so PocketBase's relation-nullification-on-delete can never write into the
table. There is no hash chain (a documented decision, not an omission).

### 5.14 Authorship pinning is what makes the "delete your own row" rules safe

`weights`, `egg_records` and `vaccinations` grant delete rights to
`author = @request.auth.id` (§4.9). Nothing in the schema marks `author` as
non-writable, so a forgeable `author` would have been a privilege grant.
`authorship.pb.js` closes it by force-setting the actor field on create and
**silently reverting any change on update** — authorship is write-once — across
`cases.admitted_by`, `case_shares.shared_by`, `dispositions.performed_by`,
`egg_records.author`, `exams.examiner`, `follow_ups.created_by`,
`journal_entries.author`, `markings.applied_by`,
`medication_administrations.administered_by`, `quarantine_records.set_by`,
`vaccinations.author`, `vet_appointments.created_by`, `weights.author`.

Deliberately **not** pinned, because they are genuine assignments rather than
provenance: `aviaries.keeper`, `cases.active_carer`, `case_shares.shared_with`,
`placements.to_user`/`from_user`. And `vaccinations.vet` is not pinned either —
it names the external practice, a fact the caller is entitled to state.

Because these are `*Request` hooks, superusers and every server-side route are
exempt and must set the fields themselves.

### 5.15 `/merge-animals` is the one route whose correctness depends on the cascade list

`POST /api/federfall/merge-animals` (supervisor-only) re-points `animal` on
`cases, markings, weights, exams, egg_records, aviary_stays, vaccinations,
sponsorships` and then deletes the duplicate animal. **That list must name every
collection with a `cascadeDelete: true` relation to `animals`** — anything
omitted is silently destroyed by the delete rather than merged. Adding a new
cascading animal child without updating this route loses data with no error.

The supervisor gate also stands in for a custody check (a supervisor holds every
bird in the org); if the route is ever widened to coordinators, custody has to be
added explicitly.

### 5.16 Placement is irreversible by the person who made it

`disposition_custody.pb.js` requires full `lib_custody.holds()` for any
disposition write that would *move* the animal — create, update **and delete** —
with no correction exemption. The documented consequence: once a carer has placed
a bird in an aviary, they can no longer change where it went, withdraw it, or
delete the placement, because they lost custody the moment it moved. "Handing a
bird over is not reversible by the person who handed it over." A weaker predicate
was tried and dropped, since no state can distinguish an honest repair from a
stale carer evicting somebody else's resident. Recourse is a supervisor, not the
API.

The one exemption: deleting a case's *last* disposition (which re-opens the case)
accepts `holds() || !heldByOthers()`, and carries no `deceased` refusal —
deleting a mistaken death record must stay possible.

### 5.17 `/api/federfall/info` is unauthenticated by design

It is the only route with no auth gate at all. It reports `major.minor` only —
the patch level is withheld so that a deployed CVE fix cannot be fingerprinted —
but **it will expose the map provider's `apiKey` if the operator configured
one**, which is documented and accepted. Rate limits (`rate_limits.pb.js`, the
single writer of `settings.rateLimits`) are restored from factory defaults *by
label on every boot*, because an earlier version wiped them and shipped instances
with no brute-force brake on `auth-with-password`. The limiter keys on client IP,
which is the reverse proxy's IP unless `FEDERFALL_TRUSTED_PROXY_HEADERS` is set.

### 5.18 Remaining invariants that exist only in hooks

Short list, for completeness — none of these is visible in the rule matrix:

- **`journal_entries` must have exactly one parent.** The rule only requires
  *at least* one (`case != ""` or `aviary != ""`); `journal_entries.pb.js`
  enforces the XOR on create and update, which a rule cannot express.
- **`cases.case_number` is server-generated** per org and per year (numeric SQL
  max, with a no-op `UPDATE organisations` first to take SQLite's write lock
  before reading), backed by the unique `(org, case_number)` index.
- **`placements` handoffs move `active_carer` transactionally.** `main.pb.js`
  pins `from_user` to the case's real current carer regardless of what was sent,
  validates that `to_user` exists, is `is_active` and is in the same org, and
  then updates `cases.active_carer` in the same transaction. So the ownership
  edge of §4.5 can only be transferred through a placement.
- **`egg_records.animal` re-pointing** requires custody of the *incoming* animal
  (`animal_custody_scope.pb.js`), because a rule cannot see the incoming value of
  a relation on update. The other re-pointable animal children (`weights`,
  `markings`, `exams`) are simply frozen by rule instead — that inconsistency is
  intentional, not an oversight.
- **`intake` refuses a `deceased` animal** below coordinator: a new case on a
  dead bird means the death record was wrong, which is a correction rather than
  an admission.
- **Org settings must be read through `lib_org.js`'s `settingsOf()`**, never
  `record.get("settings")` — the latter returns a byte array inside the JSVM and
  silently made every retention window fall back to its default. Any new hook
  reading `organisations.settings` inherits this trap.

