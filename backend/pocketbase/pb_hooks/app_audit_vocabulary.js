/// <reference path="../pb_data/types.d.ts" />

// eiermann-30w.3 — eiermann's audit VOCABULARY. Every table the audit log is
// driven by, and nothing else: no machinery, no emitters.
//
// ── Why this is a file of its own ──────────────────────────────────────────
//
// zugvogel owns the audit MACHINERY (`zv_audit.js`): redaction, the diff, label
// snapshotting, actor and org resolution, the request id, the never-throw
// wrapper, the failed-login bucketing. It owns none of the WORDS. Which action
// strings exist, which collections are audited, which fields are a member of
// the public's contact details, what names a record — that is a product's
// vocabulary, and two products do not share one. federfall has cases, finders
// and medications; this app has none of them, and a shared table would be two
// disjoint halves each carrying the other's as dead weight.
//
// So: the machinery is required, the vocabulary is passed in. `REGISTRY` at the
// bottom is these tables in the shape `withRegistry()` wants.
//
// ── The tables are parsed out of this SOURCE ───────────────────────────────
//
// By the rule suite, against the live schema, and by the client's label tests,
// which have no server to ask. That is why they are not simply exported and
// read at runtime: `audit_events.action` is deliberately TEXT rather than a
// select, so the list of actions is not in the schema either, and a Flutter
// unit test cannot load a JS module. Parsing this file is the one channel both
// sides share, and it costs a formatting constraint — the tables are `^  key: {`
// and `^  KEY: "value",`, and a reformat that broke that would be caught by the
// parse guards rather than by silence.
//
// Keeping them in a file whose only job is to hold them is what makes that
// coupling tolerable.
//
// ── A clean break from audit_entries' spellings ────────────────────────────
//
// The old log stored `spot_phase_changed`; these are `spot.phase_changed`. A
// rename like that is normally forbidden — 1700000019 says so itself, and it is
// right: a stored action string is a wire value and the rows already written
// keep the old spelling forever. What makes it allowable exactly once is that
// `audit_events` starts empty and `audit_entries`' rows are not carried across
// (eiermann-30w.2). After the first row lands here, the rule applies again:
// adding an action is additive and ships as `feat`, renaming one is a wire
// change, and an older client renders an unknown action from the envelope.

// ── No require, on purpose ─────────────────────────────────────────────────
//
// This file is TABLES. It reaches for nothing, which is what lets a unit test on
// a developer's machine load it: `zv_audit.js` is vendored into the image and is
// not in this repo, so a file-level require of it would make the vocabulary
// unloadable everywhere except inside a running container — and the tables are
// exactly the half worth checking cheaply. The three severity strings below are
// zugvogel's wire values, written out rather than imported for that reason;
// `app_audit_log.js` is where the two halves meet and where a drift would show.
const SEVERITY = { INFO: "info", NOTICE: "notice", SECURITY: "security" };

// ── Action registry — the only source of truth for valid action strings ─────
//
// `domain.verb`, and WIRE VALUES throughout. A hook never sends user-facing
// text: the server does not know which language the reader speaks, and these
// rows outlive any sentence written into them — a German string stored here in
// 2026 is untranslatable in 2027 and wrong the moment somebody reads the log in
// English. The log stores `spot.phase_changed`; the client owns every word.
//
// Nothing enforces this list at write time. The coverage test does, in both
// directions: an action here with no translation, and a translation with no
// action.
const ACTIONS = {
  // ── The building ──
  SPOT_CREATED: "spot.created",
  SPOT_UPDATED: "spot.updated",
  SPOT_DELETED: "spot.deleted",
  // Refined out of an ordinary update: the phase is the Spot's whole story, and
  // "since when, and who decided" has no answer in the record itself.
  SPOT_PHASE_CHANGED: "spot.phase_changed",
  // The cron path. No human is anywhere near it, which is what actor_kind says.
  SPOT_AUTO_RESUMED: "spot.auto_resumed",

  // ── The people at the building, who are not users of this app ──
  CONTACT_CREATED: "contact.created",
  CONTACT_UPDATED: "contact.updated",
  CONTACT_DELETED: "contact.deleted",

  // ── Areas ──
  AREA_CREATED: "area.created",
  AREA_UPDATED: "area.updated",
  AREA_DELETED: "area.deleted",

  // ── Nests ──
  NEST_CREATED: "nest.created",
  NEST_UPDATED: "nest.updated",
  NEST_DELETED: "nest.deleted",
  // The one act in this app that can be ILLEGAL, which is why it is
  // coordinator-only and why it is recorded: releasing a nest from protection
  // re-enables egg removal on it.
  NEST_UNPROTECTED: "nest.unprotected",
  NEST_PROTECTED: "nest.protected",

  // ── Besuche ──
  // One Besuch is one route, one transaction and several records; it is one row
  // here, not one per child. See eiermann-30w.6.
  VISIT_RECORDED: "visit.recorded",
  VISIT_UPDATED: "visit.updated",
  VISIT_DELETED: "visit.deleted",
  VISIT_PHOTO_ADDED: "visit_photo.added",
  VISIT_PHOTO_DELETED: "visit_photo.deleted",

  // ── What was found in a nest ──
  CHECK_CREATED: "check.created",
  CHECK_UPDATED: "check.updated",
  CHECK_DELETED: "check.deleted",
  EGG_CREATED: "egg.created",
  EGG_UPDATED: "egg.updated",
  EGG_DELETED: "egg.deleted",

  // ── Findings and what follows from them ──
  FINDING_CREATED: "finding.created",
  FINDING_UPDATED: "finding.updated",
  FINDING_DELETED: "finding.deleted",
  FOLLOW_UP_CREATED: "follow_up.created",
  FOLLOW_UP_UPDATED: "follow_up.updated",
  FOLLOW_UP_RESOLVED: "follow_up.resolved",
  FOLLOW_UP_DELETED: "follow_up.deleted",

  // ── Touren ──
  TOUR_CREATED: "tour.created",
  TOUR_UPDATED: "tour.updated",
  TOUR_DELETED: "tour.deleted",
  TOUR_SPOT_ADDED: "tour_spot.added",
  TOUR_SPOT_UPDATED: "tour_spot.updated",
  TOUR_SPOT_REMOVED: "tour_spot.removed",
  TOUR_RUN_STARTED: "tour_run.started",
  TOUR_RUN_UPDATED: "tour_run.updated",
  TOUR_RUN_FINISHED: "tour_run.finished",
  TOUR_RUN_DELETED: "tour_run.deleted",

  // ── Accounts ──
  USER_INVITED: "user.invited",
  USER_UPDATED: "user.updated",
  USER_ROLE_CHANGED: "user.role_changed",
  USER_ACTIVATED: "user.activated",
  USER_DEACTIVATED: "user.deactivated",
  // An account an identity provider created for itself, carrying a role a
  // configuration chose rather than a person. eiermann-30w.5.
  USER_PROVISIONED: "user.provisioned",

  // ── Getting in ──
  AUTH_LOGIN: "auth.login",
  AUTH_LOGIN_FAILED: "auth.login_failed",
  AUTH_OAUTH2_LOGIN: "auth.oauth2_login",
  AUTH_PASSWORD_CHANGED: "auth.password_changed",
  // The CONFIRM of a reset, not the request for one: anybody can ask for the
  // mail, only the holder of the token can spend it.
  AUTH_PASSWORD_RESET: "auth.password_reset",

  // ── The organisation's own numbers ──
  RHYTHM_CHANGED: "rhythm.changed",

  // ── What left the building ──
  REPORT_EXPORTED: "report.exported",
};

const ACTION_LIST = Object.keys(ACTIONS).map((k) => ACTIONS[k]);

// ── Which collection's writes become which action ───────────────────────────
//
// The Tier A registry. One generic hook per verb is registered over every key
// here, so auditing a new collection is an entry in this table rather than a
// new hook.
//
// NOT here, and each for its own reason:
//   * `organisations` — `updateRule` is null, so there is no client write to
//     observe. The rhythm numbers reach it through one route, which emits
//     `rhythm.changed` itself.
//   * `geocode_cache`, `idempotency_keys` — infrastructure, not decisions.
//   * `audit_events` — it would record itself.
//   * the views — nothing writes to them.
//
// A CASCADING DELETE fires no request hook, which is what keeps deleting a Spot
// from writing a row per area, nest, visit, check, egg, finding and follow-up it
// took with it. The Spot's own `spot.deleted` stands for the whole subtree.
const COLLECTION_ACTIONS = {
  spots: {
    created: ACTIONS.SPOT_CREATED,
    updated: ACTIONS.SPOT_UPDATED,
    deleted: ACTIONS.SPOT_DELETED,
  },
  spot_contacts: {
    created: ACTIONS.CONTACT_CREATED,
    updated: ACTIONS.CONTACT_UPDATED,
    deleted: ACTIONS.CONTACT_DELETED,
  },
  areas: {
    created: ACTIONS.AREA_CREATED,
    updated: ACTIONS.AREA_UPDATED,
    deleted: ACTIONS.AREA_DELETED,
  },
  nests: {
    created: ACTIONS.NEST_CREATED,
    updated: ACTIONS.NEST_UPDATED,
    deleted: ACTIONS.NEST_DELETED,
  },
  visits: {
    created: ACTIONS.VISIT_RECORDED,
    updated: ACTIONS.VISIT_UPDATED,
    deleted: ACTIONS.VISIT_DELETED,
  },
  visit_photos: {
    created: ACTIONS.VISIT_PHOTO_ADDED,
    updated: null,
    deleted: ACTIONS.VISIT_PHOTO_DELETED,
  },
  nest_checks: {
    created: ACTIONS.CHECK_CREATED,
    updated: ACTIONS.CHECK_UPDATED,
    deleted: ACTIONS.CHECK_DELETED,
  },
  nest_eggs: {
    created: ACTIONS.EGG_CREATED,
    updated: ACTIONS.EGG_UPDATED,
    deleted: ACTIONS.EGG_DELETED,
  },
  findings: {
    created: ACTIONS.FINDING_CREATED,
    updated: ACTIONS.FINDING_UPDATED,
    deleted: ACTIONS.FINDING_DELETED,
  },
  follow_ups: {
    created: ACTIONS.FOLLOW_UP_CREATED,
    updated: ACTIONS.FOLLOW_UP_UPDATED,
    deleted: ACTIONS.FOLLOW_UP_DELETED,
  },
  tours: {
    created: ACTIONS.TOUR_CREATED,
    updated: ACTIONS.TOUR_UPDATED,
    deleted: ACTIONS.TOUR_DELETED,
  },
  tour_spots: {
    created: ACTIONS.TOUR_SPOT_ADDED,
    updated: ACTIONS.TOUR_SPOT_UPDATED,
    deleted: ACTIONS.TOUR_SPOT_REMOVED,
  },
  tour_runs: {
    created: ACTIONS.TOUR_RUN_STARTED,
    updated: ACTIONS.TOUR_RUN_UPDATED,
    deleted: ACTIONS.TOUR_RUN_DELETED,
  },
  users: {
    created: ACTIONS.USER_INVITED,
    updated: ACTIONS.USER_UPDATED,
    deleted: null,
  },
};

// ── What a create or a delete records ───────────────────────────────────────
//
// An ALLOWLIST, and the allowlist is the whole idea: a create row says what the
// record was made with, a delete row what it said before it went, and nothing
// arrives here because somebody added a column. A field absent from this table
// is absent from the log.
//
// Read `contentOf` beside this: the same withholding that redacts a value in a
// diff redacts it here, so a field kept out of an update is kept out of a create
// by construction rather than by two lists agreeing.
const CONTENT_FIELDS = {
  spots: ["name", "street", "postal_code", "city", "phase", "prospect_stage", "closed_reason", "paused_until"],
  spot_contacts: ["role", "is_primary"],
  areas: ["name", "sort_index"],
  nests: ["label", "species", "species_label", "status", "interval_days", "area"],
  visits: ["visited_at", "outcome", "skip_reason", "author", "author_name", "spot"],
  visit_photos: ["visit"],
  nest_checks: ["nest", "state", "real_before", "dummy_before", "real_after", "dummy_after", "removed_real", "added_dummy", "checked_at", "author_name"],
  nest_eggs: ["nest", "slot_index", "kind", "since"],
  findings: ["kind", "count", "species_label", "found_at", "author_name", "nest", "spot"],
  follow_ups: ["due_at", "reason", "resolved_at", "nest", "spot"],
  tours: ["name", "is_active", "sort_index"],
  tour_spots: ["tour", "spot", "sort_index"],
  tour_runs: ["tour", "tour_name", "started_by_name", "started_at", "finished_at"],
  users: ["name", "email", "role", "is_active", "invited_by"],
};

// ── Values that must not exist in this table at all ─────────────────────────
//
// Kept to the FACT of a change: `{field, redacted: true}`.
//
// `spot_contacts` is this app's members-of-the-public collection, and the
// reasoning is federfall's for `finders`, one domain over. A Hausmeister, an
// owner, a caretaker did not sign up for anything; their name and number are in
// this database so somebody can ring the doorbell, and a copy of them in an
// append-only table nothing can delete would outlive every correction and every
// request to be forgotten. So the log records that a contact was added at a
// building, in which role, and nothing else. `NEVER_LABELLED` is the other half:
// their rows carry an empty subject label too, or the redaction would be undone
// by the envelope.
const SENSITIVE = {
  users: ["password", "passwordConfirm", "oldPassword", "tokenKey"],
  _superusers: ["password", "passwordConfirm", "oldPassword", "tokenKey"],
  spot_contacts: ["name", "phone", "email", "note"],
  // How to get into somebody's building: a key location, an alarm code, a "ring
  // twice and ask for Frau K.". Not the coordination's to have preserved
  // unerasably either.
  spots: ["access_note"],
};

// ── Prose, withheld by FIELD NAME wherever it appears ───────────────────────
//
// A different reason from SENSITIVE, and worth keeping distinct: this is text a
// person wrote in their own words and can still correct. Leaving it in an
// append-only table would preserve the version they edited away, which is the
// same hole a retention scrub exists to close. Keyed by name, because a field
// called `note` is somebody's prose wherever it appears — and it appears on
// nine collections here.
const FREE_TEXT = [
  "note",
  "notes",
  "skip_note",
  "pause_reason",
  "position_hint",
  "caption",
];

// ── Fields that move without anybody deciding anything ──────────────────────
//
// zugvogel already ignores `created`/`updated`. These are this app's own
// derivations: `app_rhythm.js` recomputes them from a check, so they change on
// every Besuch and would bury the one field a person actually chose. The
// interval itself is NOT here — a coordinator overriding it is a decision.
//
// `previous_photo` is `app_area_photo.js` copying the outgoing file aside; a
// consequence of changing `photo`, not a second change.
const IGNORED_FIELDS = [
  "next_due_at",
  "empty_streak",
  "previous_photo",
];

// A row about one of these carries no subject label at all. See SENSITIVE.
const NEVER_LABELLED = ["spot_contacts"];

// ── What names a record, in the order it is tried ───────────────────────────
const LABEL_FIELDS = {
  spots: ["name"],
  areas: ["name"],
  nests: ["label"],
  tours: ["name"],
  tour_runs: ["tour_name"],
  users: ["name", "email"],
  // What was found, in the words the finder chose from the vocabulary view.
  findings: ["species_label"],
};

// Named by what they hang off, when they have no name of their own. Resolved
// ONE level: the target's own label fields, never its relations.
const LABEL_RELATIONS = {
  visits: { spot: "spots" },
  visit_photos: { visit: "visits" },
  nest_checks: { nest: "nests" },
  nest_eggs: { nest: "nests" },
  follow_ups: { nest: "nests", spot: "spots" },
  tour_spots: { spot: "spots" },
  // A finding with no species recorded is still about a nest, or a building.
  findings: { nest: "nests", spot: "spots" },
};

// Nothing in this app is named by a quantity the way a weight is in federfall.
const LABEL_QUANTITIES = {};

// ── Relation fields, so a changed relation stores a LABEL beside the id ─────
//
// By field NAME, which is unambiguous here: `spot` is a Spot everywhere it
// appears, `nest` a nest, `author` a person.
const RELATION_TARGETS = {
  org: "organisations",
  spot: "spots",
  area: "areas",
  nest: "nests",
  visit: "visits",
  tour: "tours",
  author: "users",
  started_by: "users",
  invited_by: "users",
  source_check: "nest_checks",
  created_from_check: "nest_checks",
  resolved_by_check: "nest_checks",
};

// No field name in this app means two different collections.
const RELATION_FIELDS = {};

// ── Other ids the row touched, copied into `refs` ───────────────────────────
//
// `spot` is deliberately absent: it has its own indexed column, and repeating it
// in a JSON blob would invite a second way to ask the same question.
const REF_FIELDS = ["nest", "visit", "area", "tour", "author"];

// ── The coarse filter ───────────────────────────────────────────────────────
//
// So the coordination can lift membership, access and sign-in events out of the
// day-to-day noise of Besuche. `notice` is the middle: not a security event, but
// not something to scroll past either.
const DEFAULT_SEVERITY = {
  "auth.login": SEVERITY.SECURITY,
  "auth.login_failed": SEVERITY.SECURITY,
  "auth.oauth2_login": SEVERITY.SECURITY,
  "auth.password_changed": SEVERITY.SECURITY,
  "auth.password_reset": SEVERITY.SECURITY,
  "user.invited": SEVERITY.SECURITY,
  "user.role_changed": SEVERITY.SECURITY,
  "user.activated": SEVERITY.SECURITY,
  "user.deactivated": SEVERITY.SECURITY,
  "user.provisioned": SEVERITY.SECURITY,
  "user.updated": SEVERITY.NOTICE,
  // Releasing a nest is the one act here that can be illegal.
  "nest.unprotected": SEVERITY.SECURITY,
  "nest.protected": SEVERITY.NOTICE,
  // Hard to undo, and invisible in the record afterwards.
  "spot.deleted": SEVERITY.NOTICE,
  "spot.phase_changed": SEVERITY.NOTICE,
  "nest.deleted": SEVERITY.NOTICE,
  "visit.deleted": SEVERITY.NOTICE,
  // The numbers every due date in the app comes out of.
  "rhythm.changed": SEVERITY.NOTICE,
  // Data leaving the system.
  "report.exported": SEVERITY.NOTICE,
};

// ── The Spot is the record everything else is filed under ───────────────────
//
// `field` is the relation most audited collections reach it by; `via` is the hop
// for the three that reach it only through a parent. Without those hops, a photo
// or an egg edited directly through the collection API would be filed under
// nothing and never appear in the building's own history.
//
// `tours`, `tour_runs` and `users` belong to no Spot at all, and correctly carry
// an empty correlation.
const SPOT_VIA = {
  visit_photos: { field: "visit", collection: "visits" },
  nest_checks: { field: "visit", collection: "visits" },
  nest_eggs: { field: "nest", collection: "nests" },
};

const REGISTRY = {
  defaultSeverity: DEFAULT_SEVERITY,
  sensitive: SENSITIVE,
  freeText: FREE_TEXT,
  ignoredFields: IGNORED_FIELDS,
  neverLabelled: NEVER_LABELLED,
  labelFields: LABEL_FIELDS,
  labelQuantities: LABEL_QUANTITIES,
  labelRelations: LABEL_RELATIONS,
  relationTargets: RELATION_TARGETS,
  relationFields: RELATION_FIELDS,
  refFields: REF_FIELDS,
  correlation: {
    collection: "spots",
    field: "spot",
    labelField: "name",
    // eiermann-30w.1: what makes these columns this app's to name instead of
    // federfall's `case_id`.
    column: "spot_id",
    labelColumn: "spot_label",
    via: SPOT_VIA,
  },
  loginFailedAction: ACTIONS.AUTH_LOGIN_FAILED,
};

module.exports = {
  SEVERITY: SEVERITY,
  ACTIONS: ACTIONS,
  ACTION_LIST: ACTION_LIST,
  COLLECTION_ACTIONS: COLLECTION_ACTIONS,
  CONTENT_FIELDS: CONTENT_FIELDS,
  SENSITIVE: SENSITIVE,
  FREE_TEXT: FREE_TEXT,
  IGNORED_FIELDS: IGNORED_FIELDS,
  NEVER_LABELLED: NEVER_LABELLED,
  LABEL_FIELDS: LABEL_FIELDS,
  RELATION_TARGETS: RELATION_TARGETS,
  DEFAULT_SEVERITY: DEFAULT_SEVERITY,
  REGISTRY: REGISTRY,
};
