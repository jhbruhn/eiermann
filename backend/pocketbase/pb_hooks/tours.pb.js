/// <reference path="../pb_data/types.d.ts" />

// The tour invariants. app_tour_rules.js holds the logic and the reasons.

onRecordCreateRequest((e) => {
  const rules = require(`${__hooks}/app_tour_rules.js`);
  rules.deriveStop(e.app, e.record, rules.callerOrg(e.auth));
  e.next();
}, "tour_spots");

onRecordUpdateRequest((e) => {
  const rules = require(`${__hooks}/app_tour_rules.js`);
  // `tour` and `spot` are both pinned by the update rule, so this re-derivation
  // is a no-op in the happy case — and the one thing standing there if that
  // rule is ever loosened to allow a reorder-plus-move in one call.
  rules.deriveStop(e.app, e.record, rules.callerOrg(e.auth));
  e.next();
}, "tour_spots");

onRecordCreateRequest((e) => {
  const rules = require(`${__hooks}/app_tour_rules.js`);
  rules.prepareRun(e.app, e.record, e.auth);
  e.next();
}, "tour_runs");

onRecordUpdateRequest((e) => {
  const rules = require(`${__hooks}/app_tour_rules.js`);
  // `original()` and not the request body: what matters is whether the STORED
  // run was already finished.
  rules.guardFinish(e.record, e.record.original().get("finished_at"));
  e.next();
}, "tour_runs");
