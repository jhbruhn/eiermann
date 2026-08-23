/// <reference path="../pb_data/types.d.ts" />

// eiermann-ldi — who recorded a fact, and when, stop being client-writable.
//
// ── What was open ──────────────────────────────────────────────────────────
//
// Measured against a real instance before the fix: an ordinary member PATCHes
// `{author_name: "GEFAELSCHT", found_at: "2020-01-01"}` onto a Fund and gets
// 200, with both values stored.
//
// `1700000011`'s update rule pinned `org`, `visit`, `spot`, `nest` and `kind`,
// under a comment saying "the note and the species label are the two things
// somebody realises afterwards — the rest is the event". The authorship fields
// were not in that list. `1700000009` has the same shape one collection over:
// it pins `visits.author`, the RELATION, and leaves `author_name`, the snapshot
// standing next to it, open.
//
// Neither is a rule somebody wrote wrongly on purpose. Both are the intent
// stated in prose beside a rule that did not carry it out, which is the shape
// the two sweeps in `test_rules.py` now exist to catch.
//
// ── Why these three fields and not the whole row ───────────────────────────
//
// `author_name` is deliberately a SNAPSHOT rather than a lookup: a closed
// account must not take the Funde and Besuche it recorded with it, and a
// chronology whose author column empties when somebody leaves the group
// describes the past wrongly. That makes it the ONLY surviving trace of who
// recorded a fact — and a text field anybody could overwrite.
//
// `found_at` is what `report.pb.js` cuts the period report on. Left writable, a
// Fund can be moved into a different reporting period, and those reports go to
// a Behörde.
//
// `author` is the relation the snapshot was taken from. Pinning one and not the
// other is how `visits` came to be half-guarded.
//
// ── Why `photo` is NOT pinned, though the issue first said it should be ────
//
// A file cannot travel in the JSON body of the transactional visit endpoint, so
// `findings.photo` is reachable only through a SECOND request after the write —
// which is exactly what eiermann-9oa is scoped to build, and its own notes name
// this rule's permissiveness as the thing that makes it possible. Pinning the
// field would refuse a filed feature to close a hole it is not part of: a photo
// is an attachment somebody adds afterwards, like the note, not a statement
// about who was there. It stays writable, and the registry in `test_rules.py`
// now says so with a reason instead of listing it as a bug.
//
// ── The shape of the change ────────────────────────────────────────────────
//
// String replacement with an asserted match, the precedent 014, 018 and 021 all
// set: a restated rule is a copy of the whole thing that drifts from the
// original while looking identical, and only these clauses change. The anchor
// is each rule's LAST clause, which is the part `1700000014` did not touch —
// that migration rewrote the role clause at the front.
//
// A replacement that matched nothing would report success while leaving the
// authorship of every recorded fact writable, so each one throws instead.

/** The clauses appended to each rule, in order, keyed by collection. */
const PINS = {
  findings: {
    anchor: ' && @request.body.kind:isset = false',
    add:
      ' && @request.body.author:isset = false' +
      ' && @request.body.author_name:isset = false' +
      ' && @request.body.found_at:isset = false',
  },
  visits: {
    anchor: ' && @request.body.author:isset = false',
    add: ' && @request.body.author_name:isset = false',
  },
};

/**
 * Appends [add] after [anchor] in [name]'s update rule, and saves.
 *
 * Throws when the anchor is absent or the clause is already there: the first is
 * a rule this migration does not recognise, and the second would append a
 * duplicate clause on a re-run.
 */
function pinFields(app, name, anchor, add, reverse) {
  const collection = app.findCollectionByNameOrId(name);
  const rule = String(collection.updateRule || "");
  const from = reverse ? anchor + add : anchor;
  const to = reverse ? anchor : anchor + add;
  if (rule.indexOf(from) === -1) {
    throw new Error(
      "authorship migration found no `" +
        from +
        "` in " +
        name +
        "'s updateRule — the rule is not what this migration assumes, and " +
        "appending to it blind would produce a clause nobody has read",
    );
  }
  collection.updateRule = rule.split(from).join(to);
  app.save(collection);
}

migrate(
  (app) => {
    for (const name of Object.keys(PINS)) {
      pinFields(app, name, PINS[name].anchor, PINS[name].add, false);
    }
  },
  (app) => {
    for (const name of Object.keys(PINS)) {
      pinFields(app, name, PINS[name].anchor, PINS[name].add, true);
    }
  },
);
