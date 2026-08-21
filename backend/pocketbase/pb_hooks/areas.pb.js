/// <reference path="../pb_data/types.d.ts" />

// The Bereich invariants. app_area_photo.js holds the logic and the reasons.
//
// Everything is required inside the handler: each one runs in its own JSVM
// context, and a file-level binding would be a ReferenceError at request time
// reported as a generic 400 on an ordinary save.

onRecordCreateRequest((e) => {
  const photo = require(`${__hooks}/app_area_photo.js`);
  // No review on create: a first photo replaces nothing. What the guard is here
  // for is a body that arrives with the review state already filled in — a new
  // Bereich that claims its pins are unchecked before it has a pin.
  photo.guardReviewFields(e.requestInfo().body || {});
  e.next();
}, "areas");

onRecordUpdateRequest((e) => {
  const photo = require(`${__hooks}/app_area_photo.js`);
  const body = e.requestInfo().body || {};
  photo.guardReviewFields(body);
  // Order matters, and only in one direction: a request that both ends the pass
  // and replaces the photo ends up FLAGGED. The replacement is the later fact
  // about the building, and the pins have not been seen against the new picture.
  photo.finishReview(e.record, body);
  // The save is handed TO the hook rather than run after it: a replacement
  // copies the outgoing photo, and that copy's reader has to still be open when
  // the save reads its bytes. Closed first, the write fails with a mime-type
  // error on a field the client never sent — measured.
  photo.startReview(e.app, e.record, () => e.next());
}, "areas");
