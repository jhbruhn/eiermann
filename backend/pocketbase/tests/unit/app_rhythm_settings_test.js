// Node tests for the validation half of the rhythm settings.
//
//   node backend/pocketbase/tests/unit/app_rhythm_settings_test.js
//
// The integration suite covers the ROUTE — who may call it, what it stores,
// what survives a merge. What it cannot do cheaply is walk every shape a number
// can arrive in, and those shapes are the whole point of this module: every one
// that gets through and is then quietly ignored produces an app working
// correctly with numbers nobody chose.
//
// `refuse` throws an `ApiError`, which does not exist outside the JSVM. It is
// stubbed below with something that carries the same code, so a test can name
// WHICH refusal it expected rather than just "it threw".

const assert = require("node:assert");
const { test } = require("node:test");
const path = require("node:path");

global.__hooks = path.join(__dirname, "..", "..", "pb_hooks");

// The JSVM's ApiError. The real one is a host binding; all this module does
// with it is throw it, and all these tests need back is the `data` key.
global.ApiError = class ApiError extends Error {
  constructor(status, message, data) {
    super(message);
    this.status = status;
    this.data = data || {};
  }
};

const settings = require(path.join(global.__hooks, "app_rhythm_settings.js"));

const CURRENT = {
  baseIntervalDays: 7,
  emptyChecksPerStep: 3,
  intervalSteps: [7, 14, 28],
  halfClutchReturnDays: 4,
  pauseAutoResume: true,
};

/** The refusal code [body] produces, or null when it is accepted. */
function refusalOf(body, current) {
  try {
    settings.validate(body, current || CURRENT);
    return null;
  } catch (error) {
    return Object.keys(error.data || {})[0] || "threw without a code";
  }
}

test("a whole number of days is what a day count has to be", () => {
  assert.equal(settings.wholeDays(7), 7);
  // A JSON body written by hand carries "7" as often as 7, and refusing that
  // would be refusing a correct answer over its spelling.
  assert.equal(settings.wholeDays("7"), 7);
  assert.equal(settings.wholeDays(settings.MAX_DAYS), settings.MAX_DAYS);

  // Everything below falls back to the DEFAULT in zv_org.js rather than
  // erroring, which is exactly why it has to be caught here: the settings
  // screen would show the value that was rejected and the ladder would use
  // another one.
  assert.equal(settings.wholeDays(0), null);
  assert.equal(settings.wholeDays(-3), null);
  assert.equal(settings.wholeDays(7.5), null);
  assert.equal(settings.wholeDays(settings.MAX_DAYS + 1), null);
  assert.equal(settings.wholeDays(""), null);
  assert.equal(settings.wholeDays(null), null);
  assert.equal(settings.wholeDays(undefined), null);
  assert.equal(settings.wholeDays("bald"), null);
  assert.equal(settings.wholeDays({}), null);
  assert.equal(settings.wholeDays([]), null);
  // `Number(true)` is 1, which would make a bool a legal one-day interval.
  assert.equal(settings.wholeDays(true), null);
  assert.equal(settings.wholeDays(false), null);
  assert.equal(settings.wholeDays(Infinity), null);
  assert.equal(settings.wholeDays(NaN), null);
});

test("a field the body omits keeps the value it has", () => {
  // PARTIAL in fact and not just in verb. A client that sends one number must
  // not blank the other four by omission — the shape of every accidental
  // settings wipe.
  const patch = settings.validate({ halfClutchReturnDays: 5 }, CURRENT);
  assert.equal(patch.half_clutch_return_days, 5);
  assert.equal(patch.base_interval_days, 7);
  assert.equal(patch.empty_checks_per_step, 3);
  assert.deepEqual(patch.interval_steps, [7, 14, 28]);
});

test("both spellings of every field are accepted", () => {
  // The route answers in camelCase and the blob stores snake_case. Somebody
  // reading the response and PATCHing it straight back has to work.
  const camel = settings.validate({ baseIntervalDays: 9, intervalSteps: [9, 18] }, CURRENT);
  const snake = settings.validate(
    { base_interval_days: 9, interval_steps: [9, 18] },
    CURRENT,
  );
  assert.deepEqual(camel, snake);
});

test("each bad number is refused under its OWN code", () => {
  // Named per field because the client puts the message under the field it is
  // about; one shared "invalid settings" would land on the wrong row.
  assert.equal(refusalOf({ baseIntervalDays: 0 }), "rhythm_base_interval_invalid");
  assert.equal(
    refusalOf({ emptyChecksPerStep: -1 }),
    "rhythm_empty_checks_per_step_invalid",
  );
  assert.equal(
    refusalOf({ halfClutchReturnDays: "bald" }),
    "rhythm_half_clutch_return_invalid",
  );
  assert.equal(refusalOf({ intervalSteps: [] }), "rhythm_interval_steps_invalid");
  assert.equal(refusalOf({ intervalSteps: 7 }), "rhythm_interval_steps_invalid");
  assert.equal(
    refusalOf({ intervalSteps: [7, "spaeter"] }),
    "rhythm_interval_steps_invalid",
  );
  assert.equal(
    refusalOf({ intervalSteps: new Array(settings.MAX_STEPS + 1).fill(7) }),
    "rhythm_interval_steps_invalid",
  );
});

test("a ladder that comes back down is refused", () => {
  // The interval is supposed to STRETCH the longer a nest has gone unused. A
  // descending ladder inverts the thing it exists for.
  assert.equal(
    refusalOf({ intervalSteps: [28, 14, 7] }),
    "rhythm_interval_steps_not_ascending",
  );
  assert.equal(
    refusalOf({ intervalSteps: [7, 28, 14] }),
    "rhythm_interval_steps_not_ascending",
  );
  // Equal rungs are fine: that is how a three-rung ladder becomes two without
  // deleting a row.
  assert.equal(refusalOf({ intervalSteps: [7, 7, 28] }), null);
});

test("a first rung below the base interval is refused", () => {
  // `nextNestState` gives an EMPTY nest steps[0] and a nest with something in
  // it the base. steps[0] < base therefore means an empty nest is checked more
  // often than a live one — backwards, and no screen in the app would say so.
  assert.equal(
    refusalOf({ baseIntervalDays: 14, intervalSteps: [7, 14, 28] }),
    "rhythm_steps_below_base",
  );
  // Raising the base alone hits it too: the stored ladder is what it lands on.
  assert.equal(refusalOf({ baseIntervalDays: 14 }), "rhythm_steps_below_base");
  // Above the base is coherent — the first empty already stretches.
  assert.equal(refusalOf({ baseIntervalDays: 7, intervalSteps: [10, 20] }), null);
});

test("an inherited inconsistency does not block an unrelated edit", () => {
  // An operator writing the settings blob by hand through the Admin UI is a
  // real and supported path, and it can leave the two fields disagreeing.
  // Refusing a Nachkontrolle edit over it would be a dead end on the one screen
  // that exists to fix it.
  const inconsistent = { ...CURRENT, baseIntervalDays: 10 };
  assert.equal(refusalOf({ halfClutchReturnDays: 6 }, inconsistent), null);
  assert.equal(refusalOf({ emptyChecksPerStep: 2 }, inconsistent), null);
  // But a client still cannot CREATE one, which is what the route is a door for.
  assert.equal(
    refusalOf({ baseIntervalDays: 12 }, inconsistent),
    "rhythm_steps_below_base",
  );
});

test("pause_auto_resume is only false when it is explicitly false", () => {
  // The cron reads it as `!== false`, so a key whose absence means true must
  // not suddenly mean false because a client sent a string.
  assert.equal(settings.validate({ pauseAutoResume: false }, CURRENT)
    .pause_auto_resume, false);
  assert.equal(settings.validate({ pauseAutoResume: "false" }, CURRENT)
    .pause_auto_resume, false);
  assert.equal(settings.validate({ pauseAutoResume: true }, CURRENT)
    .pause_auto_resume, true);
  assert.equal(settings.validate({ pauseAutoResume: "ja" }, CURRENT)
    .pause_auto_resume, true);
  // Omitted means untouched — not written at all, so nothing can flip it.
  assert.equal(
    "pause_auto_resume" in settings.validate({ baseIntervalDays: 7 }, CURRENT),
    false,
  );
});
