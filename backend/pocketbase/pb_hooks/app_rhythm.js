/// <reference path="../pb_data/types.d.ts" />

// THE RHYTHM. The only place that computes `empty_streak`, `interval_days`,
// `nests.next_due_at` and `spots.next_due_at`.
//
// Every writer calls this; nobody computes their own. That is not tidiness — two
// derivations of the same state drift, and the drift is invisible: each screen
// looks plausible and they disagree. The rule to keep is that a second
// implementation of any function below is a bug even if it is correct today.
//
// The module splits deliberately into
//
//   * PURE functions (the ladder, the date arithmetic), which have node tests
//     and can be reasoned about without a database;
//   * WRITERS, which read the org's settings and save records.
//
// ── What the ladder is for ─────────────────────────────────────────────────
//
// A nest that has been empty three times running is probably not being used. It
// still deserves a look, but not every week — so the interval stretches: 7 days
// (streak 0–2), 14 (3–5), 28 (cap). The moment anything is found — an egg, a
// chick, a dead pigeon, a bird sitting on it — the nest is live again and the
// interval drops straight back to base. The ladder climbs slowly and falls in
// one step, because the cost of the two errors is not symmetric: checking a dead
// nest too often wastes an hour, and checking a live one too rarely means a
// clutch hatches.

const EMPTY = "empty";

/** States that mean somebody actually observed the nest's contents. */
const OBSERVED = ["swapped", "partial", "empty", "untouched", "protected"];

/** States after which the nest should no longer appear in any due list. */
const RETIRING = ["gone", "protected"];

/**
 * The interval for [emptyStreak] on the ladder [steps], [perStep] empties per
 * rung.
 *
 * The last value is the cap and is deliberately reached rather than exceeded: a
 * nest empty twenty times running is checked every 28 days forever, not annually.
 * Something with a roof over it can always come back.
 */
function intervalFor(emptyStreak, steps, perStep) {
  const ladder = Array.isArray(steps) && steps.length ? steps : [7];
  const per = perStep > 0 ? perStep : 3;
  const streak = emptyStreak > 0 ? emptyStreak : 0;
  const rung = Math.min(Math.floor(streak / per), ladder.length - 1);
  return ladder[rung];
}

/**
 * [isoish] (a PocketBase timestamp) shifted by [days], in PocketBase's format.
 *
 * PocketBase writes `2026-08-21 00:10:27.735Z` — a space, not a `T`, which
 * `Date.parse` does not accept. Getting this wrong yields `Invalid Date`, then
 * `NaN`, then a nest whose next_due_at is empty: it silently drops out of every
 * due list instead of erroring.
 */
function addDays(isoish, days) {
  const text = String(isoish || "").trim();
  const parsed = new Date(text.replace(" ", "T"));
  if (isNaN(parsed.getTime())) return "";
  parsed.setUTCDate(parsed.getUTCDate() + Number(days || 0));
  return (
    parsed.toISOString().replace("T", " ").replace(/\.\d+Z$/, ".000Z")
  );
}

/** The earlier of two PocketBase timestamps; either may be empty. */
function earlier(a, b) {
  const left = String(a || "");
  const right = String(b || "");
  if (!left) return right;
  if (!right) return left;
  return left < right ? left : right;
}

/**
 * The nest's state after a check with [state] and a previous [emptyStreak].
 *
 * Returns `{ emptyStreak, intervalDays, dueFromCheck, retire }`, or `null` when
 * the check says nothing about the nest's contents and the rhythm must not move
 * at all.
 *
 * `not_reachable` is that case, and it is the important one. It means somebody
 * tried and could not get to the nest — which is NOT the observation of an empty
 * nest. Advancing the ladder on it would stretch the interval on a nest nobody
 * has seen, and that is the single direction the rhythm must never drift. Same
 * reasoning as a skipped visit, which produces no checks at all.
 */
function nextNestState(state, emptyStreak, settings) {
  if (OBSERVED.indexOf(state) === -1 && RETIRING.indexOf(state) === -1) {
    return null;
  }

  // A nest that is gone, or that a protected species has moved into, leaves the
  // due lists. `gone` because there is nothing to check; `protected` because
  // nothing may be DONE — and a work list that keeps offering an item nobody is
  // allowed to act on trains people to ignore the list.
  if (RETIRING.indexOf(state) !== -1) {
    return {
      emptyStreak: 0,
      intervalDays: settings.baseIntervalDays,
      dueFromCheck: "",
      retire: state,
    };
  }

  if (state === EMPTY) {
    const streak = (emptyStreak > 0 ? emptyStreak : 0) + 1;
    return {
      emptyStreak: streak,
      intervalDays: intervalFor(
        streak,
        settings.intervalSteps,
        settings.emptyChecksPerStep,
      ),
      dueFromCheck: null, // filled by the caller from the check date
      retire: null,
    };
  }

  // Anything found — an egg, a chick, a bird sitting on it — puts the nest back
  // at base. One step down, however high the ladder had climbed.
  return {
    emptyStreak: 0,
    intervalDays: settings.baseIntervalDays,
    dueFromCheck: null,
    retire: null,
  };
}

/** The org's rhythm numbers, with the documented defaults. */
function settingsFor(app, orgId) {
  const orgs = require(`${__hooks}/zv_org.js`);
  const raw = orgs.settingsOf(app, orgId);
  return {
    baseIntervalDays: orgs.positiveNumber(raw, "base_interval_days", 7),
    emptyChecksPerStep: orgs.positiveNumber(raw, "empty_checks_per_step", 3),
    intervalSteps: orgs.positiveNumberList(raw, "interval_steps", [7, 14, 28]),
    halfClutchReturnDays: orgs.positiveNumber(raw, "half_clutch_return_days", 4),
    pauseAutoResume: raw.pause_auto_resume !== false,
  };
}

/**
 * Applies one completed check to its nest, and to the follow-ups it settles or
 * creates. Returns the nest record (already saved).
 *
 * Order matters here: the open follow-ups are resolved BEFORE a new one is
 * created. A nest that is a Halbgelege twice running would otherwise accumulate
 * two open Nachkontrollen for one situation, and the due list would show the
 * same nest twice with two different dates.
 */
function applyCheck(app, nest, check) {
  const settings = settingsFor(app, nest.get("org"));
  const state = String(check.get("state") || "");
  const checkedAt = String(check.get("checked_at") || "");

  resolveFollowUps(app, nest, check);

  const next = nextNestState(state, Number(nest.get("empty_streak") || 0), settings);
  if (next) {
    nest.set("empty_streak", next.emptyStreak);
    nest.set("interval_days", next.intervalDays);
    if (next.retire) {
      nest.set("next_due_at", "");
      if (next.retire === "gone") nest.set("status", "gone");
    } else {
      nest.set("next_due_at", addDays(checkedAt, next.intervalDays));
    }
    app.save(nest);
  }

  if (state === "partial") {
    createHalfClutchFollowUp(app, nest, check, settings);
  }
  return nest;
}

/**
 * Resolves the open Halbgelege follow-ups on this nest.
 *
 * Resolved by a LATER CHECK on this nest, never by time passing and never by a
 * skipped visit — the whole point of a Nachkontrolle is that somebody went back
 * and looked. Any observed state settles it: the swap was completed, or the nest
 * is empty now, or a protected bird has moved in. Each of those ends the
 * situation the follow-up was created for. `partial` again does not, and the new
 * one created below carries a fresh date.
 */
function resolveFollowUps(app, nest, check) {
  const state = String(check.get("state") || "");
  if (OBSERVED.indexOf(state) === -1 && RETIRING.indexOf(state) === -1) return;
  if (state === "partial") return;

  const open = app.findRecordsByFilter(
    "follow_ups",
    "nest = {:nest} && resolved_at = ''",
    "-due_at",
    200,
    0,
    { nest: nest.id },
  );
  for (const followUp of open) {
    followUp.set("resolved_at", String(check.get("checked_at") || ""));
    followUp.set("resolved_by_check", check.id);
    app.save(followUp);
  }
}

/**
 * Creates the Nachkontrolle for a Halbgelege.
 *
 * `due_at` is COMPUTED NOW AND STORED. Deriving it later from the org's current
 * `half_clutch_return_days` would mean that changing the setting retroactively
 * moves every outstanding follow-up — including overdue ones, which would
 * silently become on time. A plan is a fact about a decision somebody made.
 */
function createHalfClutchFollowUp(app, nest, check, settings) {
  const collection = app.findCollectionByNameOrId("follow_ups");
  const followUp = new Record(collection);
  followUp.set("org", nest.get("org"));
  followUp.set("spot", nest.get("spot"));
  followUp.set("nest", nest.id);
  followUp.set("reason", "half_clutch");
  followUp.set(
    "due_at",
    addDays(String(check.get("checked_at") || ""), settings.halfClutchReturnDays),
  );
  followUp.set("created_from_check", check.id);
  app.save(followUp);
  return followUp;
}

/**
 * When a Spot was "added", for the fallback that counts from it.
 *
 * `created` is a zero value on a record that has not been written yet, and that
 * is exactly when this runs for a Spot being created: the create hook computes
 * the date BEFORE the write, so the single save carries it and the response body
 * matches the row. Anything that is not a plausible timestamp therefore reads as
 * now — which is what "when it was added" means for a Spot being added.
 */
function addedAt(spot) {
  const created = String(spot.get("created") || "");
  const parsed = new Date(created.replace(" ", "T"));
  if (isNaN(parsed.getTime()) || parsed.getUTCFullYear() < 2000) {
    return new DateTime().string();
  }
  return created;
}

/**
 * The date [spot] SHOULD carry — computed, not written.
 *
 * The minimum of every active nest's due date and every open follow-up's. The
 * follow-up usually wins, which is the point of it: a Halbgelege is due before
 * the ladder would have come back round.
 *
 * A Spot with NO NESTS is due after the base period, counted from its last
 * visit — or from when it was added, if nobody has been yet. Empty does not mean
 * done: a building with no nests recorded is a building nobody has looked at
 * properly, and the one thing it must not do is disappear from the list.
 *
 * A paused or closed Spot has no due date at all — and neither has an Erkundung,
 * which needs a conversation rather than a visit. `paused_until` brings a paused
 * one back by itself (the cron), which is why pausing is safe to use liberally.
 *
 * Split out of [recomputeSpotDue] so a *request* hook can put the date on the
 * record it is about to save instead of saving it a second time afterwards. A
 * record mutated after `e.next()` never reaches the response body — the reply is
 * already on the wire — so a second save would answer the client with the value
 * it just replaced.
 */
function spotDueFor(app, spot) {
  const phase = String(spot.get("phase") || "");
  if (phase === "paused" || phase === "closed" || phase === "prospect") {
    return "";
  }

  const settings = settingsFor(app, spot.get("org"));
  let due = "";

  const nests = app.findRecordsByFilter(
    "nests",
    "spot = {:spot} && status = 'active'",
    "next_due_at",
    500,
    0,
    { spot: spot.id },
  );
  let counted = 0;
  for (const nest of nests) {
    const nestDue = String(nest.get("next_due_at") || "");
    // A brand-new nest has no due date yet: it has never been checked. It is due
    // NOW, not never — so it pulls the Spot's date to the base period from the
    // nest's creation rather than being skipped.
    const effective = nestDue || addDays(
      String(nest.get("created") || ""), settings.baseIntervalDays,
    );
    due = earlier(due, effective);
    counted += 1;
  }

  const followUps = app.findRecordsByFilter(
    "follow_ups",
    "spot = {:spot} && resolved_at = ''",
    "due_at",
    200,
    0,
    { spot: spot.id },
  );
  for (const followUp of followUps) {
    due = earlier(due, String(followUp.get("due_at") || ""));
  }

  if (!counted && !followUps.length) {
    const visits = app.findRecordsByFilter(
      "visits",
      "spot = {:spot} && outcome = 'checked'",
      "-visited_at",
      1,
      0,
      { spot: spot.id },
    );
    const from = visits.length
      ? String(visits[0].get("visited_at") || "")
      : addedAt(spot);
    due = addDays(from, settings.baseIntervalDays);
  }

  return due;
}

/**
 * Writes [spotDueFor]'s answer to the stored Spot [spotId], for a caller that
 * has already saved whatever else it changed — the visit endpoint, and anything
 * that alters a nest or a follow-up.
 *
 * A hook that is still holding the record it is about to write should call
 * [spotDueFor] instead and set the field itself: two saves of one Spot from one
 * request is the "two transitions from one stale original" shape.
 */
function recomputeSpotDue(app, spotId) {
  let spot;
  try {
    spot = app.findRecordById("spots", String(spotId));
  } catch (_) {
    return null;
  }
  spot.set("next_due_at", spotDueFor(app, spot));
  app.save(spot);
  return spot;
}

module.exports = {
  // pure
  intervalFor: intervalFor,
  addDays: addDays,
  earlier: earlier,
  nextNestState: nextNestState,
  OBSERVED: OBSERVED,
  RETIRING: RETIRING,
  // writers
  settingsFor: settingsFor,
  applyCheck: applyCheck,
  resolveFollowUps: resolveFollowUps,
  createHalfClutchFollowUp: createHalfClutchFollowUp,
  spotDueFor: spotDueFor,
  recomputeSpotDue: recomputeSpotDue,
};
