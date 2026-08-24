/// <reference path="../pb_data/types.d.ts" />

// eiermann-30w.4 — Tier A of the audit log: every write that goes through the
// ordinary collection API becomes one named domain event.
//
// ── Why *Request hooks, and why after e.next() ──────────────────────────────
//
// `RecordRequestEvent` is the only event kind carrying `e.auth`,
// `e.requestInfo()` and `e.realIP()`. A model hook gets a `RecordEvent`, which
// has no authenticated caller at all, and an audit row with no actor answers
// half the question it exists for. So these are the *Request variants.
//
// `e.next()` runs FIRST in every handler: it performs the save, and it THROWS
// when the save is rejected, which skips the emit entirely. No phantom rows for
// writes that never happened — a member trying to release a protected nest is
// refused by `app_nest_rules.js`, and nothing lands here.
//
// The mirror image is the accepted trade: the audit row cannot roll the domain
// write back. Which is exactly why `emit()` swallows its own errors instead of
// propagating them. Failing to RECORD that somebody released a protected nest
// must not become a failure to DO it, with the person standing in an attic
// holding a phone. And that contract does double duty here, because of the next
// paragraph: a throwing emit would abort the very write it was observing.
//
// ── Measured: the ordering is belt, and the transaction is braces ───────────
//
// The emit uses `e.app`, which during a request hook is the TRANSACTION app, so
// the audit row joins the request's own transaction rather than following it.
// Inverting this handler — emit first, `e.next()` second — and running the rule
// suite left it fully green, including the assertion that a member's refused
// release writes no row. This file loads second of the `*.pb.js` alphabetically,
// well before `nests.pb.js`, so its handler is the OUTER one and that emit
// certainly ran; the row is simply gone, rolled back with everything else the
// refused request touched.
//
// So the phantom-row property is really the transaction's, and `e.next()` first
// is the belt over those braces. Both are kept: the ordering is what makes the
// property true by reading rather than by knowing which app object `emit` was
// handed, and a future emit given `$app` instead would lose the braces without
// a word. What must NOT be concluded from this is that the ordering is checked
// by that assertion — it is not, and inverting the two is a change no test in
// this repo currently catches.
//
// ── Why there is no per-collection handler ──────────────────────────────────
//
// One generic body per verb, registered over every key of the vocabulary's
// COLLECTION_ACTIONS. The body asks the record which collection it belongs to
// and looks the action up there, so auditing a new collection is a map entry
// rather than a new hook.
//
// That is forced as much as chosen. A handler runs in an isolated JSVM context
// where file-level bindings — including a table defined ten lines above it —
// are out of scope, and referencing one throws `ReferenceError` at REQUEST
// time, which PocketBase reports as a generic 400 on an ordinary operation. So
// there is no `const audit = require(...)` at the top of this file, not even
// for the collection list in the registration argument: the rule suite sweeps
// `*.pb.js` for file-level declarations, and repeating the require is the price
// of the runtime.
//
// ── What a cascading delete does NOT write ──────────────────────────────────
//
// Cascade deletes fire no request hook. That is what keeps deleting one Spot
// from writing a row per area, contact, nest, visit, photo, check, egg, finding,
// follow-up and tour stop it took with it — see the delete-effect registry in
// the rule suite for the full list, which is eleven relations deep. The Spot's
// own `spot.deleted` row stands for the whole subtree, and it is written from
// the record while it still exists.
//
// ── NOT here ────────────────────────────────────────────────────────────────
//
// The custom routes (the Besuch, the tours, the rhythm numbers) never fire
// request hooks at all, and neither do the export, the auto-resume cron or the
// auth flows. Those are eiermann-30w.5 and 30w.6.


onRecordCreateRequest(
  (e) => {
    e.next();
    require(`${__hooks}/app_audit_log.js`).emitRecordChange(e, "created");
  },
  ...require(`${__hooks}/app_audit_log.js`).AUDITED_COLLECTIONS,
);

onRecordUpdateRequest(
  (e) => {
    // Captured BEFORE the save: afterwards `original()` is the new state.
    const before = e.record.original().fieldsData();
    // Which fields the request ASKED to change. Needed because some changes are
    // invisible in the record — a new password leaves only a rotated tokenKey
    // behind, and an email change rotates that too, so the diff alone cannot
    // tell the two apart. See refine() in app_audit_log.js.
    let bodyKeys = [];
    try {
      bodyKeys = Object.keys(e.requestInfo().body || {});
    } catch (_) {
      // Not a shape we can read — the diff alone still describes the change.
    }
    e.next();
    require(`${__hooks}/app_audit_log.js`).emitRecordChange(e, "updated", before, {
      bodyKeys: bodyKeys,
    });
  },
  ...require(`${__hooks}/app_audit_log.js`).AUDITED_COLLECTIONS,
);

onRecordDeleteRequest(
  (e) => {
    e.next();
    require(`${__hooks}/app_audit_log.js`).emitRecordChange(e, "deleted");
  },
  ...require(`${__hooks}/app_audit_log.js`).AUDITED_COLLECTIONS,
);
