/// <reference path="../pb_data/types.d.ts" />

// POST /api/eiermann/visit. app_visit.js holds the logic and the reasons.
//
// Everything is required inside the handler: each one runs in its own JSVM
// context, and a file-level binding would be a ReferenceError at request time
// reported as a generic 400.

routerAdd(
  "POST",
  "/api/eiermann/visit",
  (e) => {
    const lib = require(`${__hooks}/app_visit.js`);
    const ROUTE = "POST /api/eiermann/visit";

    // The gate, from the one place that states it (app_auth.js). This used to be
    // written out here as `is_active && role != null`, which is the PRE-014
    // clause: `guest` is a non-null role, so a self-registered OAuth2 account
    // behind the wall could WRITE A BESUCH through this endpoint. Measured while
    // eiermann-fi2.8 was gating the report routes, and fixed in all four at once.
    const { auth } = require(`${__hooks}/app_auth.js`).requireMember(e);

    const body = e.requestInfo().body || {};
    const key = String(e.request.header.get("Idempotency-Key") || "").trim();
    // Passing the body in: a key reused for a DIFFERENT visit is a 409, not a
    // replay of the first one.
    const cached = lib.replay(e.app, key, auth.id, ROUTE, body);
    if (cached) {
      // The retry button's whole purpose: the same key returns the same answer
      // instead of a second visit.
      return e.json(cached.status, cached.body);
    }

    let result;
    // One transaction. A throw anywhere inside rolls back the entire visit,
    // which is the point: a visit where three of eight nests were written is
    // indistinguishable from three nests somebody chose not to touch.
    e.app.runInTransaction((txApp) => {
      result = lib.writeVisit(txApp, auth, body);

      // ONE row for the whole Besuch (eiermann-30w.6). A visit writes a visit,
      // a check per nest, eggs, findings and photos, and none of it fires a
      // request hook, so Tier A sees none of it — which is the right outcome
      // twice over: those records are the consequences of ONE human act, and a
      // feed with a row per nest would bury the act in its own detail. The
      // children go in `detail` instead, as counts and states.
      //
      // Inside the transaction and with `txApp`, so the row commits with the
      // writes it describes and rolls back with them. And below the `replay`
      // branch above, which returns before ever reaching here: a retried
      // request is the same Besuch, and a second row would say it happened
      // twice.
      const audit = require(`${__hooks}/app_audit_log.js`);
      const states = {};
      for (const c of result.checks || []) {
        states[c.state] = (states[c.state] || 0) + 1;
      }
      const kinds = {};
      for (const f of result.findings || []) {
        kinds[f.kind] = (kinds[f.kind] || 0) + 1;
      }
      let visitRecord = null;
      try {
        // Read back rather than assembled by hand: the record carries the org,
        // the author and the `spot` the registry files this row under, and one
        // indexed read is cheaper than four ways to get them slightly wrong.
        visitRecord = txApp.findRecordById("visits", result.visit);
      } catch (_) {
        visitRecord = null;
      }
      audit.emit(e, audit.ACTIONS.VISIT_RECORDED, {
        app: txApp,
        record: visitRecord,
        org: String(auth.getString("org") || ""),
        correlationId: String(body.spot || ""),
        subject: {
          collection: "visits",
          id: String(result.visit || ""),
          label: visitRecord ? audit.subjectLabel(visitRecord, txApp) : "",
        },
        detail: {
          outcome: String(body.outcome || ""),
          checks: (result.checks || []).length,
          states: states,
          findings: (result.findings || []).length,
          kinds: kinds,
        },
      });

      // Stored INSIDE the transaction. Outside it, a crash between the two would
      // leave a visit that no retry can recognise — and the retry would write a
      // second one.
      lib.remember(txApp, key, auth.id, ROUTE, 200, result, body);
    });

    return e.json(200, result);
  },
  $apis.requireAuth(),
);
