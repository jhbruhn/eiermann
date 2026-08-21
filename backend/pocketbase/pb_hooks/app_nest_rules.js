/// <reference path="../pb_data/types.d.ts" />

// Nest invariants: the derived Spot, pin clamping, and the species guard.
//
// A module, `require`d inside each handler (see CLAUDE.md on JSVM contexts).

/** Species that must never have their eggs touched. */
const PROTECTED = "protected";

/**
 * Derives `spot` from the nest's `area`.
 *
 * `nests.spot` is denormalised so the map, the due list and the urgency ranking
 * read one table instead of joining two. The cost of a denormalised field is
 * that it can disagree with its source, so the client does not get a say: the
 * value is taken from the area on every write. A nest whose `spot` disagreed
 * with its `area` would appear on one building's map and in another's due list,
 * and no screen would show the contradiction.
 */
function deriveSpot(app, record, callerOrg) {
  const { refuse, CODES } = require(`${__hooks}/app_refuse.js`);
  const areaId = String(record.get("area") || "");
  if (!areaId) {
    refuse(CODES.nestNeedsArea, "a nest requires an area");
  }
  let area;
  try {
    area = app.findRecordById("areas", areaId);
  } catch (err) {
    refuse(CODES.nestAreaNotFound, `area not found: ${areaId}`);
  }

  // THE CROSS-TENANT CHECK, and the reason it has to be here.
  //
  // The create rule says `@request.body.org = @request.auth.org`, which is
  // satisfied by sending your own org. If this function then took `org` from the
  // area, a caller could send their own org with a FOREIGN area id: the rule
  // would pass, and the hook would quietly move the row into the other
  // organisation. Deriving a tenancy field from a parent the caller chose is
  // only safe once the parent has been checked against the caller.
  //
  // An access rule cannot do this check: it sees `@request.body.area` as an id,
  // not as a row it can dereference. This is trap 11 exactly — rules are the
  // security boundary, invariants across records need a hook.
  const areaOrg = String(area.get("org") || "");
  if (String(callerOrg || "") !== areaOrg) {
    // Deliberately the SAME code as a missing area: whether an id exists in
    // another organisation is not something a caller gets to learn, and a
    // distinct code would tell them.
    refuse(CODES.nestAreaNotFound, `area not found: ${areaId}`);
  }

  record.set("spot", area.get("spot"));
  record.set("org", areaOrg);
}

/**
 * Clamps `pin_x`/`pin_y` into 0…1.
 *
 * Clamped rather than rejected. These arrive from a drag gesture, and a pin
 * dropped exactly on the edge routinely computes to 1.0000000002 — failing the
 * write there would mean a volunteer cannot place a nest at the edge of a photo,
 * which is where roof nests actually are. What must not happen is a value like
 * 1.7 being stored: the nest would sit off the photo forever, invisible on the
 * only screen that shows it.
 */
function clampPins(record) {
  const { refuse, CODES } = require(`${__hooks}/app_refuse.js`);
  for (const field of ["pin_x", "pin_y"]) {
    const raw = record.get(field);
    if (raw === null || raw === undefined || raw === "") continue;
    const value = Number(raw);
    if (isNaN(value)) {
      refuse(CODES.nestPinNotNumeric, `${field} must be a number`);
    }
    record.set(field, Math.min(1, Math.max(0, value)));
  }
}

/**
 * The protected-species guard, species half.
 *
 * City pigeons are feral domestic animals and not specially protected. Jackdaws,
 * wood pigeons, swifts and kestrels sitting in the same attics ARE, and
 * interfering with their clutches is prohibited under §44 BNatSchG. This
 * confusion is the largest real risk this app can AMPLIFY, precisely because it
 * makes clutch swapping faster and more routine.
 *
 * So the asymmetry is deliberate and load-bearing:
 *
 *   * anyone may mark a nest `protected` — the volunteer standing in front of a
 *     jackdaw must be able to stop the process immediately, without finding a
 *     coordinator first;
 *   * only the coordination may take it back, because that reopens the egg-swap
 *     path on a nest somebody had reason to flag.
 *
 * [isCoordinator] is passed in rather than read here: the caller has the auth
 * record, and a guard that resolves its own authority is a guard that can be
 * called without any.
 */
function guardSpecies(record, previous, isCoordinator) {
  const { refuse, CODES } = require(`${__hooks}/app_refuse.js`);
  const next = String(record.get("species") || "");
  if (previous === PROTECTED && next !== PROTECTED && !isCoordinator) {
    // The client names the law and the species — it has the ARB and this hook
    // does not know who is reading.
    refuse(
      CODES.nestProtectedNeedsCoordinator,
      "releasing a protected nest requires the coordinator role",
    );
  }
}

/**
 * Whether eggs may be touched on [nest]. Called by every egg-writing path.
 *
 * Exported now, before `nest_eggs` exists, because the ordering is the point:
 * the guard exists before the first egg, not after. A Phase 04 endpoint that
 * forgets to call it is a bug this function's existence makes visible.
 */
function assertEggsAllowed(nest) {
  if (String(nest.get("species") || "") !== PROTECTED) return;
  // The refusal that matters most is also the one that must not be a German
  // string here: §44 BNatSchG is worth explaining properly, and only the client
  // can do that in the reader's language, with the species label it already has
  // on the record.
  const { refuse, CODES } = require(`${__hooks}/app_refuse.js`);
  refuse(
    CODES.nestProtectedNoEggChanges,
    `egg changes refused: nest ${nest.id} is a protected species`,
  );
}

module.exports = {
  PROTECTED,
  deriveSpot,
  clampPins,
  guardSpecies,
  assertEggsAllowed,
};
