/// <reference path="../pb_data/types.d.ts" />

// eiermann-uga — the "due soon" window becomes proportional to the interval.
//
// Both urgency ladders opened their rank-2 branch with a FIXED `+7 days`
// window, and the base interval is also 7 days. A nest checked today gets
// `next_due_at = today + 7` (`app_rhythm.js`, `addDays(checkedAt, intervalDays)`),
// and `today+7 <= DATE('now','+7 days')` is true — so rank 2. Rank 3 needs
// `interval_days >= 8` and was therefore STRUCTURALLY UNREACHABLE at the base
// interval: "Diese Woche fällig" was not a phase a healthy nest passed through,
// it was its entire cycle, day 0 to day 6. Same for a Spot with no nests, whose
// fallback is `lastVisit + base`.
//
// Which is precisely the failure the two view migrations warn about in their own
// comments — a colour that is always on is a colour nobody reads. The bug was
// invisible because every individual row was coloured correctly; the LADDER was
// broken, not any rung of it.
//
// ── Why the window cannot be a constant ────────────────────────────────────
//
// A smaller constant (2, 3 days) fixes today and breaks on the day somebody
// changes the numbers. `base_interval_days` lives in `organisations.settings`
// (`zv_org.js`), and eiermann-uwd.2 builds the UI for editing it. A fixed
// 2-day window degenerates the moment a coordinator types 3 — the same silent
// everything-is-warning display, a new cause, and nothing pointing at it. Any
// constant is wrong once the number it must stay below is user-editable.
//
// So the window is a FRACTION of the interval behind the row's own date: a
// quarter ROUNDED UP, floor one day. A 7-day nest warns 2 days out, a 28-day
// nest 7 days out. Scale-free, and it needs no access to the settings.
//
// Rounded up because SQLite's `/` on integers truncates: a plain `/ 4` gives a
// 7-day nest a ONE-day window, which is the opposite error to the one being
// fixed — measured, before `(x + 3) / 4` went in.
//
// ── Why the two views ask differently ──────────────────────────────────────
//
// NESTS have the interval stored. `nests.interval_days` is what the rhythm
// decided at check time, so the view divides that — the authoritative record of
// the decision, not a re-derivation of it.
//
// SPOTS have no interval column and must not get one: it would copy into a
// second table what `nests` already holds, and a copy drifts while looking
// identical. Instead the interval is reconstructed from two stored dates. The
// hook computes every Spot date as `somewhen + someInterval`, and `somewhen` is
// the last checked visit — or the Spot's creation, for a building nobody has
// been to (`addedAt`). So `next_due_at - COALESCE(last checked visit, created)`
// returns the interval that produced the date, whether it came from a nest, a
// Nachkontrolle, or the no-nests fallback.
//
// That reconstruction is exact in the common case and TOO SMALL in one: when
// the nest that won the MIN was not the one checked at the last visit, the
// subtraction can come out small or negative. It floors at one day, which is
// the direction this is allowed to fail — a narrow window means less warning,
// never a false "in Rhythmus" on something already due. The rank-0 and rank-1
// branches are pure date comparisons and are reached first, so nothing overdue
// can hide behind a bad window. Same asymmetry the ladder itself is built on:
// checking a dead nest too often wastes an hour, checking a live one too rarely
// loses a clutch.
//
// ── Why a string replacement and not two restated views ────────────────────
//
// Migration 014 set this precedent for the access rules, and `spot_overview`'s
// own header argues for it from the other side: restating the projection copies
// the whole thing into a second file, and the copy drifts from the original
// while looking identical. One clause changes here, so one clause is what this
// file touches — and the count is asserted, because a replacement that matched
// nothing would leave both ladders broken and report success.
//
// `MAX(a, b)` is SQLite's scalar max, and it returns NULL if either argument is
// NULL — hence the COALESCE around `interval_days`, which is nullable
// (`1700000008_nests.js:134`). A null interval yields a one-day window rather
// than a NULL that would quietly drop the row to rank 3.
//
// Every computed column stays ONE line: the view parser reads the SELECT list
// itself and follows neither a `--` comment nor an expression across newlines.

const OLD_NEST = "WHEN DATE(n.next_due_at) <= DATE('now', '+7 days') THEN 2";
const NEW_NEST =
  "WHEN DATE(n.next_due_at) <= DATE('now', '+' || CAST(MAX(1, (COALESCE(n.interval_days, 0) + 3) / 4) AS TEXT) || ' days') THEN 2";

const OLD_SPOT = "WHEN DATE(s.next_due_at) <= DATE('now', '+7 days') THEN 2";
const NEW_SPOT =
  "WHEN DATE(s.next_due_at) <= DATE('now', '+' || CAST(MAX(1, CAST((JULIANDAY(DATE(s.next_due_at)) - JULIANDAY(DATE(COALESCE((SELECT MAX(v.visited_at) FROM visits v WHERE v.spot = s.id AND v.outcome = 'checked'), s.created))) + 3) / 4 AS INTEGER)) AS TEXT) || ' days') THEN 2";

/**
 * Replaces [from] with [to] in the view query of [name], and saves it.
 *
 * Throws when the fragment is not there. A migration that silently matched
 * nothing is the failure mode this whole file exists to undo.
 */
function swapWindow(app, name, from, to) {
  const collection = app.findCollectionByNameOrId(name);
  const query = String(collection.viewQuery || "");
  if (query.indexOf(from) === -1) {
    throw new Error(
      "urgency-window migration found no `" +
        from +
        "` in " +
        name +
        "'s viewQuery — the rank-2 window is not what this migration assumes, " +
        "and rewriting it blind would replace a ladder nobody has read",
    );
  }
  collection.viewQuery = query.split(from).join(to);
  app.save(collection);
}

migrate(
  (app) => {
    swapWindow(app, "nest_state", OLD_NEST, NEW_NEST);
    swapWindow(app, "spot_overview", OLD_SPOT, NEW_SPOT);
  },
  (app) => {
    swapWindow(app, "nest_state", NEW_NEST, OLD_NEST);
    swapWindow(app, "spot_overview", NEW_SPOT, OLD_SPOT);
  },
);
