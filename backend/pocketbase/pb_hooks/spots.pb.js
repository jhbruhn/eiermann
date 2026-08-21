/// <reference path="../pb_data/types.d.ts" />

// The Spot lifecycle guard. app_spot_phase.js holds the transition graph and
// every reason; these handlers only wire it in.
//
// Both hooks are *Request* hooks, so the rejection reaches the client as a 400
// with its message instead of failing after the write.

onRecordCreateRequest((e) => {
  // previous = null: a create is not a transition. A group with a long-standing
  // arrangement can enter a building as `active` on day one, and inventing a
  // prospect phase it never went through would be a false history.
  require(`${__hooks}/app_spot_phase.js`).apply(e.record, null);
  e.next();
}, "spots");

onRecordUpdateRequest((e) => {
  // `e.record` already carries the submitted changes; `original()` is the
  // stored row. A transition is a statement about both, which is precisely what
  // an access rule cannot see.
  const previous = String(e.record.original().get("phase") || "");
  require(`${__hooks}/app_spot_phase.js`).apply(e.record, previous);
  e.next();
}, "spots");
