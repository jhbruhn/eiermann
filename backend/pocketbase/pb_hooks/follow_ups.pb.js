/// <reference path="../pb_data/types.d.ts" />

// eiermann-z3u — a follow-up written through the collection API moves the Spot.
//
// ── What was wrong ─────────────────────────────────────────────────────────
//
// `spotDueFor` takes the minimum over the Spot's active nests AND its open
// follow-ups, and the follow-up usually wins — that is the entire point of a
// Nachkontrolle: a Halbgelege is due back before the ladder would have come
// round. But `recomputeSpotDue` was called from exactly two places, the visit
// route (`app_visit.js`) and the auto-resume cron, and `follow_ups` carried no
// hooks at all.
//
// The collection is directly writable on purpose. `1700000011`'s createRule
// admits a member's MANUAL follow-up — "den Riegel nächste Woche nochmal
// ansehen" is a legitimate note to the team — and lets its note and its date be
// adjusted afterwards. Every one of those paths left `spots.next_due_at` at
// whatever the last visit had computed, so a reminder somebody entered for
// Tuesday did not pull the building forward: the Spot stayed "im Rhythmus" until
// some later visit happened to recompute it. The one screen that would have
// shown the truth is the dossier, which reads the follow-ups themselves.
//
// Measured before the fix: a Spot with a follow-up due yesterday sat at rank 3.
//
// ── Why the REQUEST hooks and not the after-success ones ───────────────────
//
// `onRecordAfterCreateSuccess` and friends fire for every save of the record,
// including the ones this app makes internally — and the visit transaction makes
// several. It creates a Halbgelege follow-up, resolves the open ones on the nest
// it just checked, and then recomputes the Spot ONCE, last, deliberately:
//
//   "Last, and after everything else: the Spot's date is the minimum over the
//    nests and follow-ups this visit just changed."
//
// After-success hooks would recompute the Spot again for each of those saves,
// inside that transaction, from a Spot record re-read mid-flight — which is the
// "two transitions from one stale original" shape CLAUDE.md warns about, paid
// for with a read and a write per follow-up on the hottest route in the app.
//
// The `*Request` hooks fire only for calls that came through the API. The visit
// route's internal `app.save` does not trip them, so the two paths do not
// overlap and neither needs to know about the other. That separation is the
// whole design here; it is also why this file registers no logic of its own
// beyond choosing when to ask.
//
// ── Three verbs, because all three move the minimum ────────────────────────
//
// Creating an open follow-up can only pull the date EARLIER, but the other two
// can push it later, and a fix that only handled create would be the same bug
// with a smaller surface:
//
//   * an update adjusts `due_at` — the rule permits exactly that, and moving a
//     reminder a week out has to move the Spot with it;
//   * a delete removes a reminder that turned out to be unnecessary, and the
//     Spot must fall back to whatever its nests say rather than keeping a date
//     whose only source is gone.
//
// The delete hook reads the Spot id BEFORE `e.next()`. Afterwards the record is
// deleted and there is nothing left to ask.
//
// ── Why after `e.next()` and not before ────────────────────────────────────
//
// `spotDueFor` reads the follow-ups back out of the database, so it has to run
// once the write is actually in — computed first, it would return the minimum
// over the world as it was and store the answer to the previous question.
//
// The usual warning about mutating a record after `e.next()` does not apply:
// that one is about the record the response body was already built from. This
// writes a DIFFERENT record, the Spot, which no reply here carries.
//
// Everything is required inside each handler in the absolute `${__hooks}` form:
// each runs in its own JSVM context, and a file-level binding is a
// ReferenceError at request time that reaches the client as a generic 400.

onRecordCreateRequest((e) => {
  e.next();
  const rhythm = require(`${__hooks}/app_rhythm.js`);
  rhythm.recomputeSpotDue(e.app, e.record.get("spot"));
}, "follow_ups");

onRecordUpdateRequest((e) => {
  e.next();
  const rhythm = require(`${__hooks}/app_rhythm.js`);
  rhythm.recomputeSpotDue(e.app, e.record.get("spot"));
}, "follow_ups");

onRecordDeleteRequest((e) => {
  // Read first: after the delete there is no record to ask which Spot this was.
  const spotId = e.record.get("spot");
  e.next();
  const rhythm = require(`${__hooks}/app_rhythm.js`);
  rhythm.recomputeSpotDue(e.app, spotId);
}, "follow_ups");
