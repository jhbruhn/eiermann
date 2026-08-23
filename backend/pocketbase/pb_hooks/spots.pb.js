/// <reference path="../pb_data/types.d.ts" />

// The Spot lifecycle guard. app_spot_phase.js holds the transition graph and
// every reason; these handlers only wire it in.
//
// Both hooks are *Request* hooks, so the rejection reaches the client as a 400
// with its message instead of failing after the write.

onRecordCreateRequest((e) => {
  const phase = require(`${__hooks}/app_spot_phase.js`);
  // previous = null: a create is not a transition. A group with a long-standing
  // arrangement can enter a building as `active` on day one, and inventing a
  // prospect phase it never went through would be a false history.
  phase.apply(e.record, null);
  // A Spot created active is due from its first second — the base period counted
  // from today. One created as an Erkundung is not due at all.
  phase.setDue(e.app, e.record);
  e.next();
}, "spots");

onRecordUpdateRequest((e) => {
  const phase = require(`${__hooks}/app_spot_phase.js`);
  // `e.record` already carries the submitted changes; `original()` is the
  // stored row. A transition is a statement about both, which is precisely what
  // an access rule cannot see.
  const previous = String(e.record.original().get("phase") || "");
  phase.apply(e.record, previous);
  const now = String(e.record.get("phase") || "");
  // Only when the phase actually moved. Nothing else in this collection can
  // change the date, and re-deriving it on every rename would put four extra
  // queries behind every form save.
  const moved = previous !== now;
  if (moved) phase.setDue(e.app, e.record);

  // Everything the audit row needs, read BEFORE the write goes through.
  // `original()` is the stored row and the whole reason the comparison above
  // works; once `e.next()` has run there is no "before" left to read.
  const org = e.record.get("org");
  const id = e.record.id;
  // The name AT THE TIME. A live lookup later would say somebody closed
  // "Bahnhofstraße 12" when what they closed was called something else that day.
  const label = e.record.getString("name");
  // The reason a human typed, quoted rather than spoken — the one case a hook
  // may store prose, because the prose is not the server's own.
  const detail = now === "closed"
    ? e.record.getString("closed_reason")
    : e.record.getString("pause_reason");

  e.next();

  // AFTER the write, and the ordering is the point. `e.next()` is what performs
  // it, and a failure in there — a rule, a validation, a later hook — leaves
  // this line unreached. Emitting first would write "Rita closed this building"
  // for a close that never happened, into a table nothing can correct.
  //
  // The Spot record holds its CURRENT phase and nothing else, so without this
  // row "since when, and who decided" has no answer anywhere. `emit` never
  // throws, so recording the transition cannot cost the transition.
  if (moved) {
    const audit = require(`${__hooks}/app_audit.js`);
    const actor = audit.actorOf(e);
    audit.emit(e.app, {
      org: org,
      action: audit.ACTIONS.spotPhaseChanged,
      actorId: actor.id,
      actorLabel: actor.label,
      targetType: audit.TARGETS.spot,
      target: id,
      targetLabel: label,
      field: audit.FIELDS.phase,
      fromValue: previous,
      toValue: now,
      detail: detail,
    });
  }
}, "spots");

// Deleting a Spot destroys the whole memory of a building — every visit, every
// check, every Bereich photo, and the caretaker's phone number — and answers
// 200 with nothing left behind that says it happened. This row is the exception.
onRecordDeleteRequest((e) => {
  // Read while the record still exists. After `e.next()` it is gone, and a row
  // that could only say "something was deleted" is not an audit trail.
  //
  // The id is kept although nothing will ever resolve it again: two deletions
  // of two buildings with the same name are two different acts, and the id is
  // what separates them.
  const org = e.record.get("org");
  const id = e.record.id;
  const label = e.record.getString("name");

  e.next();

  // Only once the delete actually went through. A refused delete that logged
  // itself would be worse than no log — it would report a building's whole
  // memory destroyed while the building is still there.
  const audit = require(`${__hooks}/app_audit.js`);
  const actor = audit.actorOf(e);
  audit.emit(e.app, {
    org: org,
    action: audit.ACTIONS.spotDeleted,
    actorId: actor.id,
    actorLabel: actor.label,
    targetType: audit.TARGETS.spot,
    target: id,
    targetLabel: label,
  });
}, "spots");
