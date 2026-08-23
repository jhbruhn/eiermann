/// <reference path="../pb_data/types.d.ts" />

// eiermann-m0r — "noch nicht erfasst" stops borrowing a due rank and gets one.
//
// ── What was wrong ─────────────────────────────────────────────────────────
//
// A Spot with no nests recorded still carries a date: `app_rhythm.js` puts it a
// base period out from the last checked visit, or from the day it was added if
// nobody has been (`spotDueFor`'s no-nests fallback). That date is a placeholder
// meaning "come back and look", and this view ranked it as if it were a visit
// falling due — so an unsurveyed building sat among the buildings in rhythm and,
// once the placeholder passed, among the genuinely overdue.
//
// While the rank-2 window was as wide as the base interval the row at least
// stayed visible, but only because EVERY row was (eiermann-uga). With the
// proportional window it spends its first days on rank 3: green, "in Rhythmus",
// about a building nobody has been inside.
//
// A building nobody has surveyed is a different KIND of work from a nest falling
// due. It needs an Erfassung, not a visit in the rhythm — and the ladder had no
// way to say so, because every rung it owned was a degree of due-ness. Migration
// 006 already writes the sentence this rung is named after: empty does not mean
// done.
//
// ── Why the branch pre-empts the dates ─────────────────────────────────────
//
// The new branch is tested BEFORE the three date comparisons, which is the same
// shape `nest_state` gives `protected` and for the same reason: a date that
// describes nothing anybody recorded should not decide a rank. Two consequences,
// and both are the point.
//
// An unsurveyed Spot whose placeholder has passed ranks 4 rather than 0. It is
// not overdue for a visit — nobody knows yet what there is to visit. Left on
// rank 0 it would be indistinguishable from a building whose nests are genuinely
// due, and the survey signal would blink out exactly when the building has been
// neglected longest, which is the reverse of useful.
//
// And it never goes quiet: rank 4 sorts directly under the due ranks, above the
// Erkundungen, and the dashboard counts it. What it stops doing is claiming a
// colour that means something else.
//
// ── Why an open follow-up takes it back ────────────────────────────────────
//
// The second NOT EXISTS is not defensive noise. `spotDueFor` dates a Spot from
// its open follow-ups BEFORE it reaches the no-nests fallback, so a Spot with no
// nests and an open follow-up carries a REAL date somebody entered — a manual
// Nachfassen on a caretaker, most often. Ranking that row "Erfassung ausstehend"
// would bury a dated commitment behind a worklist entry. The rung means "there
// is no date here worth reading", so it has to be false wherever there is one.
//
// The two conditions therefore mirror `spotDueFor`'s own fallback test
// (`!counted && !followUps.length`) clause for clause. They have to: the rank and
// the date are two statements about one row, and if they disagree the row says
// one thing in its colour and another in its date.
//
// ── `status = 'active'`, matching the hook ─────────────────────────────────
//
// `spotDueFor` counts active nests only, so a Spot whose nests are all `gone`
// takes the no-nests fallback — and this rung follows it there. That is the
// agreement above being kept rather than a judgement about that case: whether a
// building whose nests have all gone is "unsurveyed" or something else with a
// name of its own is a product question, filed separately. What is NOT open is
// whether the rank may disagree with the date beside it.
//
// ── The renumbering is a wire change ───────────────────────────────────────
//
// `urgency` is an integer contract: `SpotUrgency.rank` parses it, the list sorts
// on it server-side (`urgency,name,id`, with keyset paging riding on that
// order), and `/spots?urgency=N` puts it in a URL a reader can bookmark. So the
// new rung cannot be appended at 7 — it would sort below the closed Spots — and
// inserting it at 4 moves prospect, paused and closed up by one. Hence `feat!:`
// and a major version: an old client against a new server would label the
// Erkundungen "Erfassung ausstehend".
//
// ── Three replacements, not a restated view ────────────────────────────────
//
// Same precedent as 014 and 018: a view definition restated in full is a copy
// that drifts from the original while looking identical. Only the three `THEN`
// values change, so only those are touched — which also keeps this migration off
// the rank-2 window clause that 018 owns. Each replacement asserts it matched,
// because a swap that matched nothing would leave a half-renumbered ladder and
// report success.
//
// The inserted branch stays ONE line: the view parser reads the SELECT list
// itself and follows an expression across neither a newline nor a `--` comment.

const NO_NESTS = "NOT EXISTS (SELECT 1 FROM nests n WHERE n.spot = s.id AND n.status = 'active')";
const NO_FOLLOW_UPS = "NOT EXISTS (SELECT 1 FROM follow_ups f WHERE f.spot = s.id AND (f.resolved_at IS NULL OR f.resolved_at = ''))";

// Applied in this order so the shifted values cannot collide: `closed` vacates 7
// before nothing needs it, `paused` moves into 6, `prospect` into 5, and the new
// branch takes the 4 `prospect` just left. Reversed on the way down.
const UP = [
  ["WHEN s.phase = 'closed' THEN 6", "WHEN s.phase = 'closed' THEN 7"],
  ["WHEN s.phase = 'paused' THEN 5", "WHEN s.phase = 'paused' THEN 6"],
  [
    "WHEN s.phase = 'prospect' THEN 4",
    `WHEN s.phase = 'prospect' THEN 5 WHEN ${NO_NESTS} AND ${NO_FOLLOW_UPS} THEN 4`,
  ],
];

/**
 * Replaces [from] with [to] in `spot_overview`'s view query, and saves it.
 *
 * Throws when the fragment is absent, for the reason in the header: a silent
 * no-op here leaves rungs pointing at each other's meanings.
 */
function swapRank(app, from, to) {
  const collection = app.findCollectionByNameOrId("spot_overview");
  const query = String(collection.viewQuery || "");
  if (query.indexOf(from) === -1) {
    throw new Error(
      "survey-rung migration found no `" +
        from +
        "` in spot_overview's viewQuery — the ladder is not what this migration " +
        "assumes, and renumbering it blind would relabel rungs nobody has read",
    );
  }
  collection.viewQuery = query.split(from).join(to);
  app.save(collection);
}

migrate(
  (app) => {
    for (const [from, to] of UP) swapRank(app, from, to);
  },
  (app) => {
    for (let i = UP.length - 1; i >= 0; i -= 1) {
      swapRank(app, UP[i][1], UP[i][0]);
    }
  },
);
