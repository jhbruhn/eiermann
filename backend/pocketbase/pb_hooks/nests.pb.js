/// <reference path="../pb_data/types.d.ts" />

// The nest invariants. app_nest_rules.js holds the logic and the reasons.

onRecordCreateRequest((e) => {
  const rules = require(`${__hooks}/app_nest_rules.js`);
  // The caller's own org, from the auth record — never from the body. The body
  // is what is being checked.
  const callerOrg = e.auth ? String(e.auth.getString("org")) : "";
  rules.deriveSpot(e.app, e.record, callerOrg);
  rules.clampPins(e.record);
  // previous = "": nothing to un-protect on create.
  rules.guardSpecies(e.record, "", false);
  e.next();
}, "nests");

onRecordUpdateRequest((e) => {
  const rules = require(`${__hooks}/app_nest_rules.js`);
  // `area` is pinned by the update rule, so re-deriving is a no-op in the happy
  // case — and the one that matters if that rule is ever loosened.
  const callerOrg = e.auth ? String(e.auth.getString("org")) : "";
  rules.deriveSpot(e.app, e.record, callerOrg);
  rules.clampPins(e.record);
  rules.guardSpecies(
    e.record,
    String(e.record.original().get("species") || ""),
    !!e.auth && String(e.auth.getString("role")) === "coordinator",
  );
  e.next();
}, "nests");
