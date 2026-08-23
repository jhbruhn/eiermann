/// <reference path="../pb_data/types.d.ts" />

// eiermann-uwd.2 — reading and WRITING the org's rhythm numbers.
//
// ── Why this is a route and not a PATCH on `organisations` ─────────────────
//
// `organisations.updateRule` is null and stays null. Migration 002 says why:
// `settings` is the only JSON field in this database, and putting it behind a
// form as raw JSON is how a malformed blob silently disables every
// org-configurable window — a value that fails to parse does not error, it
// falls into a default, and the app then works correctly with numbers nobody
// chose. federfall shipped two inert features exactly that way.
//
// So the settings blob is never written as a blob. This module takes five
// TYPED numbers, checks each one, and merges them into whatever else the blob
// holds. A client cannot reach the JSON, only these fields.
//
// ── Why the reads go through app_rhythm.settingsFor ────────────────────────
//
// Because that is the function the rhythm itself uses. A second reader would
// apply its own defaults, and then the settings screen would show 7 while the
// ladder used 14 — the "two derivations drift, and the drift is invisible"
// failure, applied to the numbers rather than to the dates.
//
// ── The validation is where the value of this file is ──────────────────────
//
// Each refusal below is a number that would have produced a plausible-looking
// app doing the wrong thing:
//
//   * zero or negative — `positiveNumber` falls back to the default, so the
//     screen would report the value that was rejected and the rhythm would use
//     another;
//   * a ladder that DESCENDS — the interval shortens the longer a nest has been
//     empty, which inverts the whole point of the ladder;
//   * a first rung BELOW the base interval — an empty nest would then be checked
//     more often than one with eggs in it. Backwards, and nothing on any screen
//     would say so.
//
// An upper bound exists for the same reason a lower one does, not because 400
// days is dangerous: it is the number somebody types when they mean 40, and a
// nest that comes back round in the next decade has silently left the work.

/** The largest interval that still describes work somebody does. */
const MAX_DAYS = 365;

/** The longest ladder worth having. */
const MAX_STEPS = 10;

/**
 * A whole number in `[1, MAX_DAYS]`, or null when [value] is not one.
 *
 * Strings are accepted because a JSON body written by hand carries `"7"` as
 * often as `7`, and refusing that would be refusing a correct answer over its
 * spelling. Anything else — a float, a bool, an object, an empty string — is
 * null, which the caller turns into a refusal naming the field.
 */
function wholeDays(value) {
  if (value === null || value === undefined || value === "") return null;
  if (typeof value === "boolean") return null;
  const number = Number(value);
  if (!isFinite(number)) return null;
  if (Math.floor(number) !== number) return null;
  if (number < 1 || number > MAX_DAYS) return null;
  return number;
}

/**
 * The org's numbers as the rhythm itself sees them — defaults filled in.
 *
 * `pauseAutoResume` comes back too, although it is not an interval: it belongs
 * to the same screen and the same blob, and the cron that reads it
 * (`spot_auto_resume.pb.js`) has no other way of being configured.
 */
function read(app, orgId) {
  const rhythm = require(`${__hooks}/app_rhythm.js`);
  const settings = rhythm.settingsFor(app, orgId);
  return {
    baseIntervalDays: settings.baseIntervalDays,
    emptyChecksPerStep: settings.emptyChecksPerStep,
    intervalSteps: settings.intervalSteps,
    halfClutchReturnDays: settings.halfClutchReturnDays,
    pauseAutoResume: settings.pauseAutoResume,
  };
}

/**
 * Validates [body] against [current], and returns the settings keys to merge.
 *
 * PARTIAL: a field the body does not carry keeps the value it has. That makes
 * the route a PATCH in fact and not just in verb — a client that sends one
 * number cannot blank the other four by omission, which is the shape of every
 * accidental settings wipe.
 *
 * Refuses through `app_refuse` like every other refusal in this app, so the
 * client gets a code it can translate rather than an English sentence.
 */
function validate(body, current) {
  const refuser = require(`${__hooks}/app_refuse.js`);
  const patch = {};

  const touchesBase =
    "base_interval_days" in body || "baseIntervalDays" in body;
  const touchesSteps = "intervalSteps" in body || "interval_steps" in body;

  const base = touchesBase
    ? wholeDays(
        "baseIntervalDays" in body
          ? body.baseIntervalDays
          : body.base_interval_days,
      )
    : current.baseIntervalDays;
  if (base === null) {
    refuser.refuse(
      refuser.CODES.rhythmBaseIntervalInvalid,
      "base interval must be a whole number of days between 1 and " + MAX_DAYS,
    );
  }
  patch.base_interval_days = base;

  const perStep = "emptyChecksPerStep" in body || "empty_checks_per_step" in body
    ? wholeDays(
        "emptyChecksPerStep" in body
          ? body.emptyChecksPerStep
          : body.empty_checks_per_step,
      )
    : current.emptyChecksPerStep;
  if (perStep === null) {
    refuser.refuse(
      refuser.CODES.rhythmEmptyChecksPerStepInvalid,
      "empty checks per step must be a whole number of at least 1",
    );
  }
  patch.empty_checks_per_step = perStep;

  const half = "halfClutchReturnDays" in body || "half_clutch_return_days" in body
    ? wholeDays(
        "halfClutchReturnDays" in body
          ? body.halfClutchReturnDays
          : body.half_clutch_return_days,
      )
    : current.halfClutchReturnDays;
  if (half === null) {
    refuser.refuse(
      refuser.CODES.rhythmHalfClutchReturnInvalid,
      "half-clutch return must be a whole number of days between 1 and " +
        MAX_DAYS,
    );
  }
  patch.half_clutch_return_days = half;

  let steps = current.intervalSteps;
  if (touchesSteps) {
    const raw =
      "intervalSteps" in body ? body.intervalSteps : body.interval_steps;
    steps = Array.isArray(raw) ? raw.map(wholeDays) : null;
    if (
      steps === null ||
      steps.length === 0 ||
      steps.length > MAX_STEPS ||
      steps.indexOf(null) !== -1
    ) {
      refuser.refuse(
        refuser.CODES.rhythmIntervalStepsInvalid,
        "interval steps must be 1 to " +
          MAX_STEPS +
          " whole numbers of days between 1 and " +
          MAX_DAYS,
      );
    }
  }

  // ── The two cross-field rules, and why they are gated ────────────────────
  //
  // Both compare the ladder against itself or against the base, so both can be
  // violated by a state this request never touched: an operator writing the
  // settings blob by hand through the Admin UI is a real and supported path,
  // and it can leave `interval_steps` and `base_interval_days` disagreeing.
  //
  // Checked ONLY when the request changes one of the two. Otherwise a
  // coordinator adjusting the Nachkontrolle window would be refused with a code
  // about a field they did not touch and cannot see the problem in — a dead end
  // on the one screen that exists to fix it. What is prevented is a CLIENT
  // creating the inconsistency, which is what this route is the door for.
  //
  // The settings screen submits all five values together, so in practice this
  // gate never loosens anything: it only stops an inherited misconfiguration
  // from blocking an unrelated edit.
  if (touchesBase || touchesSteps) {
    // A ladder that comes back DOWN inverts the thing it exists for: the
    // interval is supposed to stretch the longer a nest has gone unused. Equal
    // rungs are fine — that is how somebody shortens a three-rung ladder to two
    // without deleting a row.
    for (let i = 1; i < steps.length; i += 1) {
      if (steps[i] < steps[i - 1]) {
        refuser.refuse(
          refuser.CODES.rhythmIntervalStepsNotAscending,
          "interval steps must not decrease: " + steps.join(", "),
        );
      }
    }

    // The first rung is what an EMPTY nest gets; the base is what a nest with
    // something in it gets. A first rung below the base means an empty nest is
    // visited more often than a live one — backwards, and no screen in the app
    // would say so.
    if (steps[0] < base) {
      refuser.refuse(
        refuser.CODES.rhythmStepsBelowBase,
        "the first interval step (" +
          steps[0] +
          ") is shorter than the base interval (" +
          base +
          "), so an empty nest would be checked more often than a live one",
      );
    }
  }
  patch.interval_steps = steps;

  if ("pauseAutoResume" in body || "pause_auto_resume" in body) {
    const raw =
      "pauseAutoResume" in body ? body.pauseAutoResume : body.pause_auto_resume;
    // Anything but an explicit false is true, matching how the cron reads it
    // (`!== false`). A settings key whose absence means true cannot suddenly
    // mean false because a client sent a string.
    patch.pause_auto_resume = raw !== false && raw !== "false";
  }

  return patch;
}

/**
 * Merges [patch] into the org's stored settings and saves it.
 *
 * **A merge, never a replacement.** `settings` is one blob shared with whatever
 * else an operator has put in it, and a route that owns five keys must not
 * delete the sixth it has never heard of. That is also why the read below goes
 * through `zv_org.js` rather than off the record directly: a JSON field hands
 * JS a `types.JSONRaw` byte array, every property access on it is `undefined`,
 * and the merge would silently produce a blob containing only these five keys.
 * The rule suite sweeps for a second reader — including, as it turned out, one
 * merely spelled out in a comment.
 *
 * Saved through `app.save`, which does not go through the access rules — so
 * `organisations.updateRule` stays null and this route remains the only door.
 */
function write(app, orgId, patch) {
  const orgs = require(`${__hooks}/zv_org.js`);
  const existing = orgs.settingsOf(app, orgId) || {};
  const merged = {};
  for (const key in existing) {
    if (Object.prototype.hasOwnProperty.call(existing, key)) {
      merged[key] = existing[key];
    }
  }
  for (const key in patch) {
    if (Object.prototype.hasOwnProperty.call(patch, key)) {
      merged[key] = patch[key];
    }
  }
  const org = app.findRecordById("organisations", String(orgId));
  org.set("settings", merged);
  app.save(org);
  return merged;
}

module.exports = {
  MAX_DAYS: MAX_DAYS,
  MAX_STEPS: MAX_STEPS,
  wholeDays: wholeDays,
  read: read,
  validate: validate,
  write: write,
};
