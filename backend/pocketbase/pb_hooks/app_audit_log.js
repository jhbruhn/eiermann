/// <reference path="../pb_data/types.d.ts" />

// eiermann-30w.3 — the audit log's emitters. Every row in `audit_events`
// (1700000024) is written from here; the tables that drive them are
// `app_audit_vocabulary.js`.
//
// Usage — `require()` INSIDE the handler, never at file level, and always in the
// absolute `${__hooks}` form:
//
//   onRecordUpdateRequest((e) => {
//     const audit = require(`${__hooks}/app_audit_log.js`);
//     const before = e.record.original().fieldsData();
//     e.next();                        // throws ⇒ nothing is logged
//     audit.emit(e, audit.ACTIONS.NEST_UPDATED, {
//       record: e.record,
//       changes: audit.diff("nests", before, e.record.fieldsData(), e.app),
//     });
//   }, "nests");
//
// This file is NOT named `*.pb.js`, so PocketBase does not load it as a hook —
// it is only ever reachable through that require. Unlike a hook file, a required
// module keeps its own file-level scope, which is why the requires below can sit
// out here at all.
//
// ── What is here and what is not ───────────────────────────────────────────
//
// The MACHINERY is zugvogel's: `zv_audit.js` holds redaction, the diff, label
// snapshotting, actor and org resolution, the request id, the never-throw
// wrapper and the failed-login bucketing — some 700 lines, identical in both
// products, whose three properties (stateless, emit never throws, no PII of the
// public) are stated in its own header rather than restated here.
//
// What is left is the BINDING and the two emitters that need this app's tables:
// `emitRecordChange`, which picks an action out of COLLECTION_ACTIONS, and
// `contentOf`, which is a CONTENT_FIELDS lookup top to bottom.
//
// ── This is the only log ──────────────────────────────────────────────────
//
// It was not, for the length of eiermann-30w: `app_audit.js` kept writing the
// old `audit_entries` from seven hand-wired call sites so the coordination did
// not stare at a screen that had stopped updating. 30w.9 retired both.

const zv = require(`${__hooks}/zv_audit.js`);
const vocab = require(`${__hooks}/app_audit_vocabulary.js`);

const ACTIONS = vocab.ACTIONS;
const COLLECTION_ACTIONS = vocab.COLLECTION_ACTIONS;
const CONTENT_FIELDS = vocab.CONTENT_FIELDS;

// The shared machinery bound to this app's tables. `diff`, `emit`,
// `emitLoginFailed`, `subjectLabel`, `labelOf`, `labelsOf`, `refsFor` and
// `relationTarget` are re-exported from here untouched.
const shared = zv.withRegistry(vocab.REGISTRY);

/**
 * The allowlisted content of [record] as change entries.
 *
 * Every line is a CONTENT_FIELDS lookup, and the allowlist is the point. The
 * borrowed half is zugvogel's: `normalize`/`clamp` off the module, `isWithheld`,
 * `relationTarget` and `labelsOf` off the bound registry — so a field withheld
 * from a diff is withheld from a create by construction, rather than by two
 * lists happening to agree.
 *
 * @param created true for a create (values land in `to`), false for a delete
 *                (they land in `from`, which is what "cleared (was X)" reads as
 *                — the right sentence for something that no longer exists).
 * @param app     resolves an allowlisted relation to a snapshotted label
 *                instead of leaving a bare id.
 */
function contentOf(collection, record, created, app) {
  const out = [];
  for (const field of CONTENT_FIELDS[collection] || []) {
    let value;
    try {
      value = zv.normalize(record.get(field));
    } catch (_) {
      continue; // not a field on this collection
    }
    // An unset field is not content. `false` and `0` are, so this cannot be a
    // truthiness test: a nest with zero eggs after a check is a fact about it.
    if (value === "" || value === null || value === undefined) continue;

    if (shared.isWithheld(collection, field)) {
      out.push({ field: field, redacted: true });
      continue;
    }
    const c = zv.clamp(value);
    const entry = created
      ? { field: field, to: c.value }
      : { field: field, from: c.value };
    if (c.truncated) entry.truncated = true;
    const target = shared.relationTarget(collection, field);
    if (target && app) {
      const label = shared.labelsOf(app, target, value);
      if (label) entry[created ? "to_label" : "from_label"] = label;
    }
    out.push(entry);
  }
  return out;
}

/**
 * The few places where the verb alone is too coarse to be worth reading.
 *
 * One update can flip several of these at once, so the FIRST match wins and the
 * order below is the priority order: the row is filed under the most
 * consequential thing that happened, and `changes` still carries the rest.
 */
function refine(collection, verb, record, changes, hints) {
  const by = {};
  for (const c of changes || []) by[c.field] = c;

  if (collection === "spots" && verb === "updated" && by.phase) {
    // The Spot holds its CURRENT phase and nothing else, so "since when, and
    // who decided" has no answer anywhere in the record.
    return {
      action: ACTIONS.SPOT_PHASE_CHANGED,
      detail: { from: by.phase.from, to: by.phase.to },
    };
  }

  if (collection === "nests" && verb === "updated" && by.species) {
    // The one act in this app that can be illegal. Releasing a nest from
    // protection re-enables egg removal on it; putting it back is worth a row
    // too, so the pair reads as a pair.
    const to = String(by.species.to || "");
    const from = String(by.species.from || "");
    if (from === "protected" && to !== "protected") {
      return {
        action: ACTIONS.NEST_UNPROTECTED,
        detail: { from: from, to: to },
      };
    }
    if (to === "protected" && from !== "protected") {
      return {
        action: ACTIONS.NEST_PROTECTED,
        detail: { from: from, to: to },
      };
    }
  }

  if (collection === "users" && verb === "updated") {
    if (by.role) {
      return {
        action: ACTIONS.USER_ROLE_CHANGED,
        detail: { from: by.role.from, to: by.role.to },
      };
    }
    if (by.is_active) {
      // Deactivation is this app's retirement path — `users.deleteRule` is
      // null, because a departed member's name still has to appear on the
      // Besuche they recorded.
      return {
        action: by.is_active.to
          ? ACTIONS.USER_ACTIVATED
          : ACTIONS.USER_DEACTIVATED,
        detail: null,
      };
    }
    // A password change is invisible in the record: PocketBase keeps the hash
    // out of fieldsData(), so a diff sees only the tokenKey it rotated — and an
    // email change rotates that too. The request body is the honest signal of
    // what was asked for, and the save has already succeeded by the time this
    // runs, so it is also the signal of what happened.
    if (hints && (hints.bodyKeys || []).indexOf("password") !== -1) {
      return { action: ACTIONS.AUTH_PASSWORD_CHANGED, detail: null };
    }
  }

  // A Nachkontrolle being ticked off is the thing anybody wants to see in this
  // log; an edit to its due date is not the same event.
  if (collection === "follow_ups" && verb === "updated" && by.resolved_at) {
    if (by.resolved_at.to) {
      return { action: ACTIONS.FOLLOW_UP_RESOLVED, detail: null };
    }
  }

  if (collection === "tour_runs" && verb === "updated" && by.finished_at) {
    if (by.finished_at.to) {
      return { action: ACTIONS.TOUR_RUN_FINISHED, detail: null };
    }
  }

  return null;
}

/**
 * The whole Tier A body: turn one collection-API write into one audit row.
 * Called from `audit_domain.pb.js` AFTER `e.next()`, so a rejected save logs
 * nothing.
 *
 * @param verb   "created" | "updated" | "deleted"
 * @param before for "updated" only, `e.record.original().fieldsData()` captured
 *               BEFORE `e.next()`.
 */
function emitRecordChange(e, verb, before, hints) {
  try {
    const record = e.record;
    const collection = String(record.collection().name);
    const spec = COLLECTION_ACTIONS[collection];
    if (!spec) return; // not an audited collection
    let action = spec[verb];
    if (!action) return; // this verb is covered elsewhere, or cannot happen

    let changes = null;
    if (verb === "created" || verb === "deleted") {
      // The same shape as an update, so one renderer in the client handles all
      // three: a create reads "set to X" and a delete "cleared (was X)", with
      // no new strings.
      changes = contentOf(collection, record, verb === "created", e.app);
    }
    if (verb === "updated") {
      changes = shared.diff(collection, before, record.fieldsData(), e.app);
      if (
        hints &&
        (hints.bodyKeys || []).indexOf("password") !== -1 &&
        !changes.some((c) => c.field === "password")
      ) {
        // Name the field that actually changed — redacted, like every other
        // credential — so the line reads as what happened rather than as an
        // internal key rotation.
        changes.push({ field: "password", redacted: true });
      }
      // A no-op PATCH, or only ignored fields moved.
      if (!changes.length) return;
    }

    let detail = null;
    const refined = refine(collection, verb, record, changes, hints);
    if (refined) {
      if (refined.action) action = refined.action;
      detail = refined.detail;
    }

    shared.emit(e, action, {
      record: record,
      subject: {
        collection: collection,
        id: record.id,
        label: shared.subjectLabel(record, e.app),
      },
      refs: shared.refsFor(record),
      changes: changes,
      detail: detail,
    });
  } catch (err) {
    // The contract, restated where it is easiest to break: this module observes
    // writes it must never break. Failing to RECORD that somebody released a
    // protected nest must not become a failure to DO it, with the person
    // standing in an attic holding a phone.
    $app
      .logger()
      .warn(
        "audit: record change not recorded",
        "verb",
        String(verb),
        "err",
        String(err),
      );
  }
}

// The vocabulary writes the severity strings out rather than importing them, so
// that it stays loadable without the vendored module. This is where the two
// halves meet, and where a drift between them would show.
if (
  vocab.SEVERITY.INFO !== zv.SEVERITY.INFO ||
  vocab.SEVERITY.NOTICE !== zv.SEVERITY.NOTICE ||
  vocab.SEVERITY.SECURITY !== zv.SEVERITY.SECURITY
) {
  $app.logger().warn("audit: vocabulary severity strings differ from zv_audit's");
}

module.exports = {
  ACTIONS: vocab.ACTIONS,
  ACTION_LIST: vocab.ACTION_LIST,
  SEVERITY: zv.SEVERITY,
  ACTOR: zv.ACTOR,
  COLLECTION_ACTIONS: vocab.COLLECTION_ACTIONS,
  AUDITED_COLLECTIONS: Object.keys(vocab.COLLECTION_ACTIONS),
  contentOf: contentOf,
  diff: shared.diff,
  emit: shared.emit,
  emitRecordChange: emitRecordChange,
  emitLoginFailed: shared.emitLoginFailed,
  subjectLabel: shared.subjectLabel,
  labelOf: shared.labelOf,
  labelsOf: shared.labelsOf,
  refsFor: shared.refsFor,
  relationTarget: shared.relationTarget,
  correlationColumns: shared.correlationColumns,
};
