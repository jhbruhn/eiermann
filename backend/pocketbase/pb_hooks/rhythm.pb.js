/// <reference path="../pb_data/types.d.ts" />

// eiermann-uwd.2 — GET/PATCH /api/eiermann/rhythm: the org's rhythm numbers.
//
// This route is the reason the numbers live in `organisations.settings` at all
// rather than as constants in the hook. A group that finds seven days too often
// in winter changes one field; nobody builds an image.
//
// ── Why a route rather than opening up `organisations` ─────────────────────
//
// `organisations.updateRule` is null and stays null — see
// `app_rhythm_settings.js` for the full reasoning. Short version: `settings` is
// the only JSON field in this database, and a malformed blob does not error, it
// falls into defaults. So no client ever writes the blob; it writes five
// checked numbers and the server merges them.
//
// ── Why GET is open to every member ────────────────────────────────────────
//
// Reading the numbers is not administration. A member looking at "in 14 Tagen"
// wants to know whether that is the base interval or a stretched one, and until
// now the client could not tell: `due_explanation.dart` deliberately refuses to
// map the settings JSON a second time (that mapping is the trap that disabled
// two federfall features), so it states the interval and stops. This route is
// the typed channel that lets it finish the sentence — and it is what unblocks
// eiermann-d8u.
//
// Writing IS administration, so PATCH names the coordinator role.
//
// ── Response, both verbs ───────────────────────────────────────────────────
// {
//   "baseIntervalDays": 7,
//   "emptyChecksPerStep": 3,
//   "intervalSteps": [7, 14, 28],
//   "halfClutchReturnDays": 4,
//   "pauseAutoResume": true
// }
//
// PATCH answers with the SAME shape, read back through the rhythm's own reader
// after the save. Not with what the client sent: a value the server normalised
// (a `"7"` that became 7) has to reach the screen as the server sees it, or the
// form goes on showing the string it typed.
//
// Nothing here is user-facing text. A refusal is a code in `data`, as everywhere
// else — the server does not know which language the reader speaks.

routerAdd(
  "GET",
  "/api/eiermann/rhythm",
  (e) => {
    // Required INSIDE the handler, absolute `${__hooks}` form: each handler runs
    // in its own JSVM context, and a file-level binding is a ReferenceError at
    // request time that reaches the client as a generic 400.
    const { org } = require(`${__hooks}/app_auth.js`).requireMember(e);
    const settings = require(`${__hooks}/app_rhythm_settings.js`);
    return e.json(200, settings.read(e.app, org));
  },
);

routerAdd(
  "PATCH",
  "/api/eiermann/rhythm",
  (e) => {
    const { org, role } = require(`${__hooks}/app_auth.js`).requireMember(e);
    if (role !== "coordinator") {
      // A 403 and not an app code: the status IS the message, and every client
      // already renders it. There is no invariant to name.
      throw new ForbiddenError("only the coordination changes the rhythm");
    }

    const settings = require(`${__hooks}/app_rhythm_settings.js`);

    // `e.requestInfo().body`, never `record.get()`: `get()` throws
    // "invalid key path - missing key" for an absent key, which would turn a
    // partial PATCH — the normal case here — into a 400 about nothing.
    let body = {};
    try {
      body = e.requestInfo().body || {};
    } catch (_) {
      body = {};
    }

    const current = settings.read(e.app, org);
    const patch = settings.validate(body, current);
    settings.write(e.app, org, patch);

    // Read back rather than echoing the patch: this is what the rhythm will
    // actually use, which is the only number worth showing on a settings screen.
    const now = settings.read(e.app, org);

    // ONE row carrying a `changes` array, not one per number.
    //
    // Filtered to what actually MOVED, because the screen submits all five on
    // every save — deliberately, since all five are what the reader was looking
    // at. Without the comparison a save that nudged one number would report
    // five, and bury it. Nothing moved at all means no row.
    //
    // Recorded because these numbers decide every due date in the app:
    // stretching the base interval quietly makes a month of work disappear off
    // the lists, and the organisation record keeps only the CURRENT value.
    const log = require(`${__hooks}/app_audit_log.js`);
    let orgName = "";
    try {
      orgName = e.app.findRecordById("organisations", org).getString("name");
    } catch (_) {
      // The label is a snapshot, not a lookup key; an unnamed org still gets
      // a row.
      orgName = "";
    }
    const moved = [
      { field: "base_interval_days", from: current.baseIntervalDays, to: now.baseIntervalDays },
      { field: "empty_checks_per_step", from: current.emptyChecksPerStep, to: now.emptyChecksPerStep },
      { field: "interval_steps", from: current.intervalSteps, to: now.intervalSteps },
      { field: "half_clutch_return_days", from: current.halfClutchReturnDays, to: now.halfClutchReturnDays },
      { field: "pause_auto_resume", from: current.pauseAutoResume, to: now.pauseAutoResume },
    ].filter((c) => String(c.from) !== String(c.to));
    if (moved.length) {
      log.emit(e, log.ACTIONS.RHYTHM_CHANGED, {
        org: org,
        subject: { collection: "organisations", id: org, label: orgName },
        changes: moved,
      });
    }

    return e.json(200, now);
  },
);
