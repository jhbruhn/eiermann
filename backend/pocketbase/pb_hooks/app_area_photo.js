/// <reference path="../pb_data/types.d.ts" />

// Replacing a Bereich photo: the review pass, server side.
//
// A module, `require`d inside each handler (see CLAUDE.md on JSVM contexts).
//
// ── Why a replacement is not a field update ────────────────────────────────
//
// A pin is a normalised coordinate ON A PHOTO. Swap the photo and every pin
// still holds the same two numbers, but they now point somewhere else in the
// building: the beam that was centre-left is bottom-right on the new shot.
// Nothing in the data is wrong, and every pin is a lie. Nobody notices until
// somebody stands in an attic looking at the wrong rafter.
//
// The alternatives were both worse. Dropping the pins on replacement throws
// away the one thing that is expensive to re-create — somebody walked the attic
// to place them. Keeping them silently is the failure above. So a replacement
// puts the Bereich into a state it announces:
//
//   * the outgoing photo is COPIED to `previous_photo`, so old and new can be
//     put side by side — without it a reviewer is guessing at what moved;
//   * `pins_need_review` goes true, and every screen that draws this photo says
//     the pins are unchecked;
//   * clearing the flag ends the pass, and the copy is deleted with it.
//
// ── The copy's reader stays open until the save has read it ────────────────
//
// `getReuploadableFile` does not copy anything by itself: it hands back a File
// whose reader still points into the filesystem it came from, and the bytes are
// pulled when the record is saved. Closing that filesystem first — which is what
// the JSVM docs' "make sure to Close()" invites — leaves the upload with an
// unreadable reader, and the failure names neither the hook nor the reader:
// PocketBase sniffs the content type off the same reader, gets nothing, and
// refuses the write with `validation_invalid_mime_type` on `previous_photo`, a
// field the client never sent. Measured, as a 400 on an ordinary replacement.
//
// So `startReview` OWNS the save: it takes `next` and calls it inside the block
// that holds the filesystem open. That is the only shape in which the lifetime
// is visible at the call site.
//
// ── The copy is a copy, not a second name for one file ─────────────────────
//
// `previous_photo` gets a NEW file key (`preserveName: false`), not the outgoing
// filename written into a second field. Both fields live in the same record
// directory, so re-using the name would leave two fields pointing at one blob —
// and PocketBase deletes the file that left `photo` after the save. The result
// would be a `previous_photo` naming a file that is gone: a review pass with
// nothing to compare against, discovered by the volunteer, not by us.
//
// ── One generation, and only while it is needed ────────────────────────────
//
// Assigning `previous_photo` replaces whatever it held, so a second replacement
// during a pass keeps exactly one older photo — the one the pins were last
// placed against. Finishing the pass deletes it. This is not tidiness: these are
// pictures of the inside of somebody's building, and storing them has to justify
// itself continuously. Once the pins are confirmed, nothing justifies the copy.

/** The fields the client may not write, in any request, ever. */
const SERVER_OWNED = "previous_photo";

/** The flag the client may only ever CLEAR — never raise. */
const FLAG = "pins_need_review";

/**
 * Whether this write carries a new photo file.
 *
 * Asked of the pending upload rather than by comparing filenames: during an
 * update request the field value is the `filesystem.File` still to be stored,
 * so a string comparison against the old name would be comparing a name to an
 * object and answering "replaced" for every write that touches anything.
 */
function isReplacement(record) {
  const pending = record.getUnsavedFiles("photo");
  return !!pending && pending.length > 0;
}

/**
 * Whether anything on this Bereich can drift — i.e. whether a pin exists.
 *
 * `pin_x > 0 || pin_y > 0` rather than a not-null test, and both halves matter.
 * (0, 0) is what "no pin" arrives as on the wire — the client's `pinOf` reads
 * that corner as absent — and a NULL fails a `> 0` comparison, so one
 * expression covers a nest that was never placed and one that was never sent.
 */
function hasPins(app, areaId) {
  const rows = app.findRecordsByFilter(
    "nests",
    "area = {:area} && (pin_x > 0 || pin_y > 0)",
    "",
    1,
    0,
    { area: areaId },
  );
  return rows.length > 0;
}

/**
 * Refuses a client write to the review state.
 *
 * Both halves are the server's for the same reason: a client that could raise
 * the flag without keeping the old photo, or drop the old photo while the flag
 * stands, would produce a Bereich that demands a comparison it cannot show. The
 * prefix test catches PocketBase's own file modifiers (`previous_photo-`
 * deletes) — the plain key is not the only way to write a file field.
 */
function guardReviewFields(body) {
  const { refuse, CODES } = require(`${__hooks}/app_refuse.js`);
  for (const key of Object.keys(body || {})) {
    if (key.indexOf(SERVER_OWNED) === 0) {
      refuse(
        CODES.areaReviewFieldNotWritable,
        `${key} is set by the photo-replacement hook, not by the client`,
      );
    }
  }
  const raw = (body || {})[FLAG];
  // Multipart sends "false" as a STRING, and a non-empty string is truthy — so
  // the truthy values are listed rather than tested. Read the other way round,
  // an area could never leave the flag behind through a form.
  const raising = raw === true || raw === 1 || raw === "1" || raw === "true";
  if (raising) {
    refuse(
      CODES.areaReviewFieldNotWritable,
      `${FLAG} is raised by replacing the photo, not by the client`,
    );
  }
}

/**
 * Ends the pass if this write clears the flag: the copy has done its job.
 *
 * The client sends `pins_need_review: false` and nothing else about files. It
 * does not have to know that a copy exists — one side of a two-field invariant
 * held by a client is a side that gets forgotten in the next screen.
 */
function finishReview(record, body) {
  if (!Object.prototype.hasOwnProperty.call(body || {}, FLAG)) return;
  // "" is how a file field is emptied; the stored blob is deleted after save.
  record.set(SERVER_OWNED, "");
}

/**
 * Starts the pass if this write replaces the photo, then saves through
 * [next].
 *
 * [next] is called by this function rather than after it, because the copied
 * file's reader has to survive until the save has pulled its bytes — see the
 * lifetime note at the top of this file. Every path calls it exactly once.
 * Deliberately silent in two cases, and both are the same argument:
 *
 *   * the FIRST photo replaces nothing, so no pin was placed against an earlier
 *     image and nothing can have drifted;
 *   * a Bereich with no pin has nothing to review — flagging it would demand a
 *     pass over an empty list and keep a picture of somebody's building for the
 *     duration of a formality.
 */
function startReview(app, record, next) {
  const outgoing = String(record.original().get("photo") || "");
  if (!isReplacement(record) || !outgoing || !hasPins(app, record.id)) {
    next();
    return;
  }

  const fsys = app.newFilesystem();
  try {
    // getReuploadableFile hands back a File whose reader still points into this
    // filesystem; the bytes are pulled during the save, under a fresh key.
    record.set(
      SERVER_OWNED,
      fsys.getReuploadableFile(`${record.baseFilesPath()}/${outgoing}`, false),
    );
    record.set(FLAG, true);
    next();
  } finally {
    // NB! from the JSVM docs: a filesystem holds resources until it is closed.
    // AFTER the save, and not one statement earlier — see the lifetime note at
    // the top of this file.
    fsys.close();
  }
}

module.exports = {
  guardReviewFields,
  finishReview,
  startReview,
};
