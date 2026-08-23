/// <reference path="../pb_data/types.d.ts" />

// The nest invariants. app_nest_rules.js holds the logic and the reasons.

onRecordCreateRequest((e) => {
  const rules = require(`${__hooks}/app_nest_rules.js`);
  // The caller's own org, from the auth record — never from the body. The body
  // is what is being checked.
  const callerOrg = e.auth ? String(e.auth.getString("org")) : "";
  const area = rules.deriveSpot(e.app, e.record, callerOrg);
  rules.clampPins(e.record);
  // After clamping: the guard judges the coordinates that would be STORED.
  rules.guardPinNeedsPhoto(e.record, area, e.requestInfo().body);
  // previous = "": nothing to un-protect on create.
  rules.guardSpecies(e.record, "", false);
  e.next();
}, "nests");

onRecordUpdateRequest((e) => {
  const rules = require(`${__hooks}/app_nest_rules.js`);
  // `area` is pinned by the update rule, so re-deriving is a no-op in the happy
  // case — and the one that matters if that rule is ever loosened.
  const callerOrg = e.auth ? String(e.auth.getString("org")) : "";
  const area = rules.deriveSpot(e.app, e.record, callerOrg);
  rules.clampPins(e.record);
  rules.guardPinNeedsPhoto(e.record, area, e.requestInfo().body);
  const previous = String(e.record.original().get("species") || "");
  rules.guardSpecies(
    e.record,
    previous,
    !!e.auth && String(e.auth.getString("role")) === "coordinator",
  );

  // Crossing the protected line, in either direction.
  //
  // Releasing a nest is the one action in this app that can be ILLEGAL — it
  // re-enables egg removal on a nest somebody marked as a protected species —
  // and the nest record afterwards looks exactly like one that was never
  // protected at all. Only this row says otherwise.
  //
  // The way IN is recorded too, and deliberately: it is what makes a release
  // legible later. "Released on the 3rd" means one thing on a nest nobody ever
  // marked and quite another on one marked in April by somebody who saw a
  // jackdaw.
  const now = String(e.record.get("species") || "");
  const crossed = previous !== now &&
    (previous === rules.PROTECTED || now === rules.PROTECTED);
  // Read before the write: after `e.next()` there is no stored "before" left,
  // and the label may itself be part of what is being changed.
  const org = e.record.get("org");
  const id = e.record.id;
  const label = e.record.getString("label");
  // The species somebody typed — a human's own words, quoted. It is the fact
  // the whole decision rested on, and it sits on a field the very next edit can
  // overwrite.
  const speciesLabel = e.record.getString("species_label");

  e.next();

  // After the write. A refused update that logged itself would record a release
  // that never happened, in a table nothing can correct.
  if (crossed) {
    const audit = require(`${__hooks}/app_audit.js`);
    const actor = audit.actorOf(e);
    audit.emit(e.app, {
      org: org,
      action: now === rules.PROTECTED
        ? audit.ACTIONS.nestProtected
        : audit.ACTIONS.nestUnprotected,
      actorId: actor.id,
      actorLabel: actor.label,
      targetType: audit.TARGETS.nest,
      target: id,
      targetLabel: label,
      field: audit.FIELDS.species,
      fromValue: previous,
      toValue: now,
      detail: speciesLabel,
    });
  }
}, "nests");
