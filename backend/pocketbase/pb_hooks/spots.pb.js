/// <reference path="../pb_data/types.d.ts" />

// The Spot lifecycle guard. app_spot_phase.js holds the transition graph and
// every reason; these handlers only wire it in.
//
// Both are *Request* hooks, so a rejection reaches the client as a 400 with its
// message instead of failing after the write.
//
// The delete hook that used to sit at the bottom is gone (eiermann-30w.9). It
// existed solely to record the deletion, and `audit_domain.pb.js` now writes
// that row generically — from the same record, at the same moment, after the
// same `e.next()`.

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

  e.next();
}, "spots");
