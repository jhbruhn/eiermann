/// <reference path="../pb_data/types.d.ts" />

// eiermann-uwd.3 — THE audit trail. Every row in `audit_entries` comes through
// here, and nothing else writes to that table.
//
// ── emit() never throws, and that is the whole contract ────────────────────
//
// This module observes writes it must never break. A coordinator releasing a
// protected nest is doing something the app exists to support; a failure to
// RECORD that must not turn into a failure to DO it. So every path below is
// wrapped, and a failure becomes a log line on the server rather than a 400 to
// somebody standing in an attic.
//
// The trade is stated plainly because it is real: a silently failed emit is a
// missing audit row, and nothing in the app will say so. That is the correct
// side to fail on for this product — the alternative is an app that stops
// working when a log table does — but it is why the emit path has no
// conditionals in it worth getting wrong, and why the registries below are
// constants rather than anything computed.
//
// ── The registries ─────────────────────────────────────────────────────────
//
// ACTIONS and FIELDS are WIRE VALUES. A hook never sends user-facing text: the
// server does not know which language the reader speaks, and these rows outlive
// any sentence written into them — a German string stored here in 2026 is
// untranslatable in 2027 and wrong the moment somebody reads the log in
// English. So the log stores `spot_phase_changed` and `phase`, and the client
// owns every word.
//
// Which makes them a contract with the client, checked by `eiermann-uwd.4`:
// that test parses both objects out of this file and fails on any entry that
// would render as its raw column name in either language. Adding an action or a
// field is therefore additive and ships as `feat` — nothing already written
// changes meaning. RENAMING one is a wire change, exactly like renaming an
// enum's wire value or a refusal code, and the rows already stored keep the old
// spelling forever.
//
// ── Why the values are wire too ────────────────────────────────────────────
//
// `from_value` and `to_value` hold `closed`, `coordinator`, `7` — the same
// strings the enums store. The client already maps every one of them for the
// screens they came from, so the log reuses those labels instead of inventing a
// second vocabulary that would drift from the first.

/**
 * Every act this app records.
 *
 * Named for what HAPPENED, not for the endpoint that did it: two routes can
 * produce the same act, and a reader of the log does not care which handler ran.
 */
const ACTIONS = {
  // ── Spots ──
  spotPhaseChanged: "spot_phase_changed",
  spotDeleted: "spot_deleted",

  // ── Nests ──
  // The one action in this app that can be illegal, which is why it is
  // coordinator-only and why it is recorded.
  nestUnprotected: "nest_unprotected",
  nestProtected: "nest_protected",
  nestDeleted: "nest_deleted",

  // ── Accounts ──
  userInvited: "user_invited",
  userRoleChanged: "user_role_changed",
  userAccessChanged: "user_access_changed",
  // eiermann-0oi: an account an identity provider created for itself.
  userProvisioned: "user_provisioned",

  // ── The organisation's own numbers ──
  rhythmChanged: "rhythm_changed",

  // ── eiermann-ycd: what left the building ──
  reportExported: "report_exported",
};

/**
 * Every column an entry can name in `field`.
 *
 * The keys are for this file; the VALUES are the contract. Each one needs a
 * label in both ARB files, and `eiermann-uwd.4` fails on any that does not —
 * because a log row reading "base_interval_days: 7 → 10" is a log row written
 * for whoever wrote the schema rather than for whoever has to read it.
 */
const FIELDS = {
  phase: "phase",
  closedReason: "closed_reason",
  pausedUntil: "paused_until",
  status: "status",
  // The protection MARK — `protected` or a plain species. Not the label
  // somebody typed, which rides along in `detail`.
  species: "species",
  speciesLabel: "species_label",
  role: "role",
  isActive: "is_active",
  baseIntervalDays: "base_interval_days",
  emptyChecksPerStep: "empty_checks_per_step",
  intervalSteps: "interval_steps",
  halfClutchReturnDays: "half_clutch_return_days",
  pauseAutoResume: "pause_auto_resume",
};

/** What an entry can be ABOUT, so the client can pick an icon and a route. */
const TARGETS = {
  spot: "spot",
  nest: "nest",
  user: "user",
  org: "org",
};

/**
 * The signed-in caller as `{id, label}`, for [emit]'s actor.
 *
 * Falls back to the email address and then to a marker, in that order, because
 * an entry with no actor at all is an entry that answers half the question it
 * exists for. The marker is a WIRE value like everything else here: the client
 * turns `system` into a sentence.
 */
function actorOf(e) {
  try {
    const auth = e && e.auth;
    if (!auth) return { id: "", label: "system" };
    let label = "";
    try {
      label = String(auth.getString("name") || "");
    } catch (_) {
      label = "";
    }
    if (!label) {
      try {
        label = String(auth.getString("email") || "");
      } catch (_) {
        label = "";
      }
    }
    return { id: String(auth.id || ""), label: label || "system" };
  } catch (_) {
    return { id: "", label: "system" };
  }
}

/**
 * Writes one audit row. NEVER THROWS.
 *
 * [entry] is `{org, action, actorId, actorLabel, targetType, target,
 * targetLabel, field, fromValue, toValue, detail}`. Everything but `org` and
 * `action` is optional.
 *
 * Saved with `app.save`, which bypasses the access rules — which is what makes
 * `createRule: null` on the collection an append-only guarantee rather than a
 * lockout: no token can write here, and this function does not use one.
 */
function emit(app, entry) {
  try {
    const collection = app.findCollectionByNameOrId("audit_entries");
    const row = new Record(collection);
    row.set("org", String(entry.org || ""));
    row.set("action", String(entry.action || ""));
    if (entry.actorId) row.set("actor", String(entry.actorId));
    // Required in the schema, so it always gets SOMETHING — an entry whose
    // actor is blank is an entry that answers half the question it exists for.
    row.set("actor_label", String(entry.actorLabel || "system"));
    if (entry.targetType) row.set("target_type", String(entry.targetType));
    if (entry.target) row.set("target", String(entry.target));
    if (entry.targetLabel) row.set("target_label", String(entry.targetLabel));
    if (entry.field) row.set("field", String(entry.field));
    // Not `if (value)`: "" and "0" are both meaningful and both falsy. An empty
    // `from_value` is the fact that there was no species recorded before.
    if (entry.fromValue !== undefined && entry.fromValue !== null) {
      row.set("from_value", String(entry.fromValue));
    }
    if (entry.toValue !== undefined && entry.toValue !== null) {
      row.set("to_value", String(entry.toValue));
    }
    if (entry.detail) row.set("detail", String(entry.detail));
    app.save(row);
    return row;
  } catch (err) {
    // The contract. This module observes writes it must never break: failing to
    // RECORD that somebody released a protected nest must not become a failure
    // to DO it, with the person standing in an attic holding a phone.
    try {
      app
        .logger()
        .warn("eiermann: audit emit failed", "err", String(err),
          "action", String((entry || {}).action || ""));
    } catch (_) {
      // Even the logger is optional here. Nothing this module does is allowed
      // to reach the caller.
    }
    return null;
  }
}

/**
 * One row per CHANGED field, and nothing at all when nothing changed.
 *
 * [changes] is `[{field, from, to}]`. Entries whose `from` and `to` are equal
 * are dropped — a form that submits five values every time (the rhythm screen
 * does, deliberately) would otherwise write five rows a save and bury the one
 * number somebody actually moved.
 *
 * Comparison is on the STRING form, because that is what gets stored: `7` and
 * `"7"` are the same row, and treating them as a change would make every save
 * from a text field look like an edit.
 */
function emitChanges(app, base, changes) {
  const written = [];
  try {
    for (const change of changes || []) {
      const from = change.from === undefined || change.from === null
        ? ""
        : String(change.from);
      const to = change.to === undefined || change.to === null
        ? ""
        : String(change.to);
      if (from === to) continue;
      const row = emit(app, {
        org: base.org,
        action: base.action,
        actorId: base.actorId,
        actorLabel: base.actorLabel,
        targetType: base.targetType,
        target: base.target,
        targetLabel: base.targetLabel,
        detail: base.detail,
        field: change.field,
        fromValue: from,
        toValue: to,
      });
      if (row) written.push(row);
    }
  } catch (_) {
    // Same contract as emit(). Nothing here reaches the caller.
  }
  return written;
}

module.exports = {
  ACTIONS: ACTIONS,
  FIELDS: FIELDS,
  TARGETS: TARGETS,
  actorOf: actorOf,
  emit: emit,
  emitChanges: emitChanges,
};
