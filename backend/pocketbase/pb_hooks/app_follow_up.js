/// <reference path="../pb_data/types.d.ts" />

// eiermann-9fn — which follow-ups a client may delete.
//
// A module, `require`d inside each handler (see CLAUDE.md on JSVM contexts).
//
// ── The distinction a rule cannot express ──────────────────────────────────
//
// `1700000011` opens `follow_ups` to deletion — `MEMBER && org = @request.auth.org`
// — because a manual reminder that turned out to be unnecessary is worth
// removing and carries no history. Its own comment then says the other half is
// enforced by a hook in this file. It was not: the file did not exist, and
// measured against a real instance a member's DELETE of a `half_clutch`
// follow-up answered 204. The comment described an intention in the voice the
// rest of the file uses for facts, which is why nothing looked missing.
//
// The rule cannot make the distinction itself for the reason CLAUDE.md gives:
// an access rule's plain field reference resolves against the stored record,
// which is fine for reading `reason` on a DELETE — but a delete rule that
// pinned `reason = "manual"` would make the row invisible to the delete
// endpoint rather than refused, and the client would get a 404 about a record
// it is holding. A refusal has to be a refusal.
//
// ── Why a Halbgelege follow-up is not the owner's to remove ────────────────
//
// It is the one deadline in this app that days of delay ruin: out of a half
// clutch a chick hatches. It is created by the visit transaction, not by a
// person, and it is resolved by exactly one thing — a LATER CHECK on the same
// nest that observed some state (`resolveFollowUps`). Not by time passing, not
// by a skipped visit, and not by somebody deciding it is handled. Deleting it
// removes that obligation with no record that it existed: the follow-up rows
// ARE the record, and the Spot simply falls back to the ladder's rhythm — since
// eiermann-z3u, immediately, because the delete now recomputes.
//
// So the allowlist is `manual` rather than a denylist of `half_clutch`. A reason
// this app grows later is server-created until somebody decides otherwise, and
// the safe default for a row a person did not write is that a person may not
// delete it. Reading it the other way round, a new reason would be deletable on
// the day it was added and nobody would notice.
//
// ── Resolving is not deleting, and stays shut ──────────────────────────────
//
// The update rule already pins `reason`, `resolved_at` and `resolved_by_check`
// against client writes, so there is no second path to the same end: a follow-up
// marked resolved by hand is a Nachkontrolle nobody carried out. This guard
// closes the last one.

/** The only reason a client may delete: the ones a client can create. */
const CLIENT_OWNED = "manual";

/**
 * Refuses deleting a follow-up the server created.
 *
 * Called BEFORE `e.next()`: a guard that ran afterwards would be describing a
 * row that is already gone.
 */
function guardDelete(record) {
  if (String(record.get("reason") || "") === CLIENT_OWNED) return;
  const { refuse, CODES } = require(`${__hooks}/app_refuse.js`);
  refuse(
    CODES.followUpNotDeletable,
    `follow-up ${record.id} was created by the rhythm, not by a client`,
  );
}

module.exports = {
  guardDelete,
};
