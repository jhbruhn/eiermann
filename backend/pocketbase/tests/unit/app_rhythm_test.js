// Node tests for the PURE half of the rhythm.
//
//   node backend/pocketbase/tests/unit/app_rhythm_test.js
//
// The ladder needs to be walked rung by rung, and the integration suite would
// have to perform twenty real visits to do it. These run in milliseconds, so the
// ladder is actually exercised instead of spot-checked at one point.
//
// `__hooks` is defined below because app_rhythm.js requires zv_org.js through it
// inside a function — the writers are not called here, but the module is loaded.

const assert = require("node:assert");
const { test } = require("node:test");
const path = require("node:path");

global.__hooks = path.join(__dirname, "..", "..", "pb_hooks");

const rhythm = require(path.join(global.__hooks, "app_rhythm.js"));

const SETTINGS = {
  baseIntervalDays: 7,
  emptyChecksPerStep: 3,
  intervalSteps: [7, 14, 28],
  halfClutchReturnDays: 4,
  pauseAutoResume: true,
};

test("the ladder stretches every three empties and then caps", () => {
  const rung = (streak) => rhythm.intervalFor(streak, [7, 14, 28], 3);
  // Base: a nest still in use.
  assert.equal(rung(0), 7);
  assert.equal(rung(1), 7);
  assert.equal(rung(2), 7);
  // Three empties running — probably not in use.
  assert.equal(rung(3), 14);
  assert.equal(rung(5), 14);
  // Six — stretch once more, and stop.
  assert.equal(rung(6), 28);
  assert.equal(rung(9), 28);
  // The cap is REACHED, not exceeded. A nest empty twenty times running is
  // still looked at monthly: something with a roof over it can come back.
  assert.equal(rung(60), 28);
});

test("a broken ladder cannot produce an undefined interval", () => {
  // Defence in depth: zv_org.positiveNumberList already rejects these, but an
  // interval of `undefined` becomes NaN in a date computation and then an empty
  // next_due_at — a nest that silently never comes due again.
  assert.equal(rhythm.intervalFor(0, [], 3), 7);
  assert.equal(rhythm.intervalFor(9, [], 3), 7);
  assert.equal(rhythm.intervalFor(5, [7], 3), 7, "a one-rung ladder never stretches");
  assert.equal(rhythm.intervalFor(0, [7, 14], 0), 7, "perStep 0 would divide by zero");
  assert.equal(rhythm.intervalFor(-4, [7, 14], 3), 7, "a negative streak is 0");
});

test("addDays handles PocketBase's format, which Date.parse does not", () => {
  // The space instead of a T is the whole trap: Date.parse returns Invalid Date,
  // arithmetic yields NaN, and the nest drops out of every due list with no
  // error anywhere.
  assert.equal(
    rhythm.addDays("2026-08-21 10:30:00.000Z", 7),
    "2026-08-28 10:30:00.000Z",
  );
  assert.equal(
    rhythm.addDays("2026-08-21T10:30:00.000Z", 7),
    "2026-08-28 10:30:00.000Z",
    "an ISO string with a T works too",
  );
  // Month and year boundaries, and February in a leap year.
  assert.equal(
    rhythm.addDays("2026-08-28 00:00:00.000Z", 7),
    "2026-09-04 00:00:00.000Z",
  );
  assert.equal(
    rhythm.addDays("2026-12-28 00:00:00.000Z", 7),
    "2027-01-04 00:00:00.000Z",
  );
  assert.equal(
    rhythm.addDays("2024-02-26 00:00:00.000Z", 4),
    "2024-03-01 00:00:00.000Z",
    "2024 is a leap year: 26 Feb + 4 = 1 Mar",
  );
  assert.equal(
    rhythm.addDays("2026-08-21 10:30:00.000Z", -3),
    "2026-08-18 10:30:00.000Z",
    "negative shifts, for the tests that need a past date",
  );
  // An unparseable input returns "" rather than a wrong date. "" reads as "no
  // due date", which is visible; a wrong date is not.
  assert.equal(rhythm.addDays("", 7), "");
  assert.equal(rhythm.addDays("not a date", 7), "");
  assert.equal(rhythm.addDays(null, 7), "");
});

test("earlier picks the earlier date and tolerates a missing one", () => {
  assert.equal(
    rhythm.earlier("2026-09-01 00:00:00.000Z", "2026-08-01 00:00:00.000Z"),
    "2026-08-01 00:00:00.000Z",
  );
  assert.equal(rhythm.earlier("", "2026-08-01 00:00:00.000Z"), "2026-08-01 00:00:00.000Z");
  assert.equal(rhythm.earlier("2026-08-01 00:00:00.000Z", ""), "2026-08-01 00:00:00.000Z");
  assert.equal(rhythm.earlier("", ""), "");
});

test("an empty nest climbs; anything found drops it straight to base", () => {
  const climb = (streak) => rhythm.nextNestState("empty", streak, SETTINGS);
  assert.deepEqual(climb(0), {
    emptyStreak: 1, intervalDays: 7, dueFromCheck: null, retire: null,
  });
  assert.equal(climb(2).emptyStreak, 3);
  assert.equal(climb(2).intervalDays, 14, "the third empty stretches it");
  assert.equal(climb(5).intervalDays, 28);
  assert.equal(climb(30).intervalDays, 28, "capped");

  // The fall is one step from any height — the two errors do not cost the same.
  // Checking a dead nest too often wastes an hour; checking a live one too
  // rarely means a clutch hatches.
  for (const state of ["swapped", "partial", "untouched"]) {
    const after = rhythm.nextNestState(state, 30, SETTINGS);
    assert.equal(after.emptyStreak, 0, state);
    assert.equal(after.intervalDays, 7, state);
    assert.equal(after.retire, null, state);
  }
});

test("not_reachable moves NOTHING — the one drift that must not happen", () => {
  // Somebody tried and could not get to the nest. That is not the observation of
  // an empty nest. Treating it as one would stretch the interval on a nest
  // nobody has seen.
  assert.equal(rhythm.nextNestState("not_reachable", 2, SETTINGS), null);
  assert.equal(rhythm.nextNestState("not_reachable", 0, SETTINGS), null);
  // And anything unrecognised is treated the same way, rather than guessed at.
  assert.equal(rhythm.nextNestState("", 2, SETTINGS), null);
  assert.equal(rhythm.nextNestState("nonsense", 2, SETTINGS), null);
});

test("gone and protected leave the due lists, for different reasons", () => {
  const gone = rhythm.nextNestState("gone", 4, SETTINGS);
  assert.equal(gone.retire, "gone");
  assert.equal(gone.dueFromCheck, "", "no due date: there is nothing to check");

  const guarded = rhythm.nextNestState("protected", 4, SETTINGS);
  assert.equal(guarded.retire, "protected");
  assert.equal(
    guarded.dueFromCheck, "",
    "nothing may be DONE here, and a work list that keeps offering an item " +
      "nobody is allowed to act on trains people to ignore the list",
  );
  assert.equal(guarded.emptyStreak, 0, "a bird is living in it — not empty");
});

test("the org's own ladder is used, not the default", () => {
  const monthly = {
    baseIntervalDays: 10,
    emptyChecksPerStep: 2,
    intervalSteps: [10, 30],
    halfClutchReturnDays: 4,
  };
  assert.equal(rhythm.nextNestState("empty", 0, monthly).intervalDays, 10);
  assert.equal(rhythm.nextNestState("empty", 1, monthly).intervalDays, 30);
  assert.equal(rhythm.nextNestState("empty", 9, monthly).intervalDays, 30);
  assert.equal(rhythm.nextNestState("swapped", 9, monthly).intervalDays, 10);
});
