/// <reference path="../pb_data/types.d.ts" />

// eiermann-jgc — the closing DATE stops being the client's, on both paths.
//
// ── What was open ──────────────────────────────────────────────────────────
//
// `app_spot_phase.js` says of this field: "Server-owned, like next_due_at: a
// client that can write the closing date can backdate a decision nobody made."
// `1700000004` pins `next_due_at` and says why in its own comment. It does not
// pin `closed_at`. The fourth instance this week of an invariant stated in prose
// beside a rule that did not carry it out.
//
// Measured against a real instance, all three paths:
//
//   * PATCHing `closed_at` onto an ACTIVE Spot answers 200 and stores nothing —
//     the hook's else-branch clears it. So an open building cannot end up
//     wearing a closing date, and the issue was wrong to say it could.
//   * PATCHing `{phase: "closed", closed_reason: …, closed_at: "2019-05-05"}`
//     answers 200 and STORES 2019. This is the real hole, and it is exactly the
//     sentence the hook comment warns about.
//   * CREATING a Spot already closed, with the same backdated field, also stores
//     2019. The create rule pins nothing at all, and the issue did not mention
//     it — which is why both rules are touched here rather than one.
//
// ── Why the rule and not the hook ──────────────────────────────────────────
//
// The hook sets the date only when the field is EMPTY, which is what lets a
// client's value survive. That condition is not a bug on its own: re-running on
// an already-closed Spot — editing its note, say — must not reset the closing
// date to now. Tightening it to "only on the transition into closed" would work
// too.
//
// The rule is the better half to change, for the reason CLAUDE.md gives: access
// rules are the security boundary, and this is a boundary question rather than a
// derivation. It also puts `closed_at` where its own comment already claims it
// is — beside `next_due_at`, guarded the same way, in the same rule. With the
// field unwritable the hook's condition becomes simply correct: empty on the
// first close, set on every write after it.
//
// ── Why `next_due_at` needs no create clause ───────────────────────────────
//
// Measured too, because the asymmetry looks like an oversight and is not: a
// create carrying `next_due_at: "2019-05-05"` answers 200 and stores the date
// the rhythm derived. The create hook assigns it UNCONDITIONALLY, so whatever
// the client sent is overwritten before the row exists. `closed_at` is
// conditional, and that single difference is the whole bug.
//
// String replacement with an asserted match, as 014, 018, 021 and 022 all do. A
// replacement that matched nothing would report success while leaving a closing
// date backdatable.

const UPDATE_ANCHOR = " && @request.body.next_due_at:isset = false";
const UPDATE_ADD = " && @request.body.closed_at:isset = false";

// The create rule carries no field guards at all, so the anchor is its whole
// text and the clause is appended to it.
const CREATE_ANCHOR = "@request.body.org = @request.auth.org";
const CREATE_ADD = " && @request.body.closed_at:isset = false";

/** Appends [add] after [anchor] in [rule], or removes it again. */
function swap(rule, anchor, add, reverse) {
  const from = reverse ? anchor + add : anchor;
  const to = reverse ? anchor : anchor + add;
  if (String(rule || "").indexOf(from) === -1) {
    throw new Error(
      "closed_at migration found no `" +
        from +
        "` in the spots rule it was aiming at — the rule is not what this " +
        "migration assumes, and appending to it blind would produce a clause " +
        "nobody has read",
    );
  }
  return String(rule).split(from).join(to);
}

migrate(
  (app) => {
    const spots = app.findCollectionByNameOrId("spots");
    spots.updateRule = swap(spots.updateRule, UPDATE_ANCHOR, UPDATE_ADD, false);
    spots.createRule = swap(spots.createRule, CREATE_ANCHOR, CREATE_ADD, false);
    app.save(spots);
  },
  (app) => {
    const spots = app.findCollectionByNameOrId("spots");
    spots.updateRule = swap(spots.updateRule, UPDATE_ANCHOR, UPDATE_ADD, true);
    spots.createRule = swap(spots.createRule, CREATE_ANCHOR, CREATE_ADD, true);
    app.save(spots);
  },
);
