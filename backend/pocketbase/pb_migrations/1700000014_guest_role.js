/// <reference path="../pb_data/types.d.ts" />

// eiermann-h7q.18 — the `guest` role, and the rule change it FORCES.
//
// Somebody arriving through an identity provider has to be able to land
// somewhere. Until now that landing place was the absence of a role: every rule
// opened with `@request.auth.role != null`, so an account with no role could
// sign in and read nothing. Migration 002 called that "a wall, not a default
// level of access", and it was right.
//
// The wall moves here, and it moves because self-registration needs a landing
// place the SHARED library can write. `zv_oauth2_provisioning.js` provisions a
// new account into a walled-off ROLE — a value it stores on the record — and it
// has no way to write "no role at all". `users.org` is a required relation on
// top of that, so a record with neither a role nor an org cannot be created.
// Either the library learns a role-less wall (eiermann-vx4) or this app gets a
// role that means "authenticated and not yet let in". This is the second.
//
// ── Why every rule has to change, and why an ALLOWLIST ─────────────────────
//
// `role != null` is satisfied by `guest`. So on the day `guest` becomes a
// storable value, every rule in this database that opened with that clause
// would hand a self-registered stranger from the identity provider member-level
// read access to every Spot, contact and nest in the organisation. Adding the
// role without this migration is the whole security model, off.
//
// The replacement NAMES the roles that may pass:
//
//     (@request.auth.role = "member" || @request.auth.role = "coordinator")
//
// rather than excluding the one that may not (`role != "guest"`). Both close
// today's hole; they differ on the day somebody adds the NEXT role. An
// exclusion list grants it everything by default and the mistake is invisible —
// exactly the failure this migration exists to undo, one role later. An
// allowlist denies it by default, and the symptom is a screen that says "no
// access" to somebody who should have it: annoying, visible, and fixed in one
// place.
//
// ── Why the rules are REWRITTEN and not restated ──────────────────────────
//
// This migration does a string replacement over the stored rules instead of
// spelling out five rules for each of a dozen collections. Restating them would
// copy the whole security model into a second file — the org scope, the
// `:isset` guards, the pinned relations — and a copy is a thing that drifts
// from the original while looking identical. What changes here is one clause,
// so one clause is what this file touches.
//
// The count is asserted afterwards: a replacement that matched nothing would
// leave the wall down and the migration would report success. That failure has
// to be loud.
//
// NB for every migration written after this one: the `MEMBER` constant is now
// the allowlist above. The rule suite sweeps for it, including over collections
// that do not exist yet.

const OLD_CLAUSE = '@request.auth.role != null';
const NEW_CLAUSE =
  '(@request.auth.role = "member" || @request.auth.role = "coordinator")';
const RULE_KINDS = [
  "listRule",
  "viewRule",
  "createRule",
  "updateRule",
  "deleteRule",
];

// Below this, something has gone wrong: at the time of writing eleven rules
// carry the clause across twelve collections. A floor rather than an exact
// number, because a later collection legitimately raises it — and the point of
// the assertion is to catch a replacement that matched NOTHING.
const MIN_REPLACEMENTS = 11;

function swapClause(app, from, to) {
  let touched = 0;
  for (const collection of app.findAllCollections()) {
    if (!collection) continue;
    let changed = false;
    for (const kind of RULE_KINDS) {
      const raw = collection[kind];
      // A rule field is a Go `*string`, so `typeof raw` is "object" and NOT
      // "string" — a string-typed guard here skips every rule in the database
      // and the migration reports success over an untouched security model.
      // Measured: the first version of this file replaced 0 of 11 rules, and
      // the count assertion below is the only reason that was noticed.
      // `null` is a real value (superuser-only) and has to be skipped, not
      // stringified: `String(null)` is the word "null".
      if (raw === null || raw === undefined) continue;
      const rule = String(raw);
      if (rule.indexOf(from) === -1) continue;
      // Assigning a plain JS string back is fine — that is how every other
      // migration in this directory writes a rule.
      collection[kind] = rule.split(from).join(to);
      changed = true;
      touched++;
    }
    if (changed) app.save(collection);
  }
  return touched;
}

migrate(
  (app) => {
    // The role first: a rule naming a value the field cannot hold is a rule
    // that refuses everybody, so the value has to exist before the rules
    // mention its absence.
    const users = app.findCollectionByNameOrId("users");
    const role = users.fields.getByName("role");
    // `guest` is deliberately LAST in the list. PocketBase does not order these
    // semantically, but the app reads the list to build a picker, and a wall is
    // not something anybody picks first.
    role.values = ["member", "coordinator", "guest"];
    app.save(users);

    const touched = swapClause(app, OLD_CLAUSE, NEW_CLAUSE);
    if (touched < MIN_REPLACEMENTS) {
      throw new Error(
        "guest-role migration replaced only " +
          touched +
          " rules, expected at least " +
          MIN_REPLACEMENTS +
          " — the wall would be down: `guest` can be stored and every rule " +
          "still passes any non-null role",
      );
    }
  },
  (app) => {
    swapClause(app, NEW_CLAUSE, OLD_CLAUSE);
    const users = app.findCollectionByNameOrId("users");
    const role = users.fields.getByName("role");
    role.values = ["member", "coordinator"];
    app.save(users);
  },
);
