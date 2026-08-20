/// <reference path="../pb_data/types.d.ts" />

// federfall-vfry — "who DID the thing" is stated by the server, never by the
// client.
//
// Usage — `require()` INSIDE the handler, `${__hooks}` absolute form:
//
//   const authorship = require(`${__hooks}/zv_authorship.js`);
//   authorship.stampActor(e, ACTOR_FIELDS);
//
// ── What belongs in an app's ACTOR_FIELDS map ───────────────────────────────
// Only fields that record an ACTOR — who wrote this, who gave this dose, who
// performed this release. Those are never a choice the client gets to make:
// they are a statement about who was authenticated, and the server is the only
// party that knows the answer.
//
// Deliberately NOT actor fields, because they name a person who is genuinely
// assignable and the caller is entitled to pick them: the member responsible
// for an enclosure, the current carer of a case, the receiving party of a
// handoff, the colleague being granted access. Getting this line wrong in the
// permissive direction lets a client forge a signature; getting it wrong in the
// strict direction breaks assignment entirely, so the map is the app's to write
// and to test.
//
// The MAP is domain. The stamping is not, which is why only the latter is here.
//
// STATELESS (see zv_audit.js): each pooled JSVM holds its own instance, so
// nothing here may cache a decision between calls.

/**
 * Force [record]'s actor field to the authenticated caller.
 *
 * [actorFields] is `{collection: field}` — the app's map. A collection that is
 * not in it is left alone, so one shared handler can be registered over a tag
 * list the app controls.
 *
 * Overwrites whatever the client sent rather than validating it: a mismatch is
 * not a validation error to report, it is a value with no standing. On create
 * the field is always stamped; on update it is only stamped when the client
 * tried to CHANGE it, so an ordinary edit does not silently reassign
 * authorship to whoever happened to save the row.
 */
function stampActor(e, actorFields, opts) {
  const record = e.record;
  if (!record) return;
  let collection = "";
  try {
    collection = String(record.collection().name);
  } catch (_) {
    return;
  }
  const field = (actorFields || {})[collection];
  if (!field) return;

  let actorId = "";
  try {
    actorId = e.auth ? String(e.auth.id || "") : "";
  } catch (_) {
    actorId = "";
  }
  // No authenticated caller: leave the field to the collection's own rules
  // rather than blanking it. A hook-driven write has no actor to name.
  if (!actorId) return;

  const isCreate = !!(opts && opts.isCreate);
  if (!isCreate) {
    let before = "";
    try {
      before = String(record.original().get(field) || "");
    } catch (_) {
      before = "";
    }
    const after = String(record.get(field) || "");
    if (before === after) return;
  }
  record.set(field, actorId);
}

module.exports = {
  stampActor: stampActor,
};
