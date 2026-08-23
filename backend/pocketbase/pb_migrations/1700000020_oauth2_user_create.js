/// <reference path="../pb_data/types.d.ts" />

// eiermann-uwd.13 — let a sign-in through an identity provider create the
// `users` record it needs.
//
// `users.createRule` is coordinator-only (1700000002): an account exists
// because somebody decided it should. An OAuth2 sign-in has NO authenticated
// caller, so that rule refused the record PocketBase creates for a first-time
// arrival — measured against the mock provider before this migration existed:
// the provisioning hook ran and picked a role, then the write came back
//
//     400 {"message":"Failed to create record."}
//     details: create rule failure: sql: no rows in result set
//
// with nothing in the response naming the rule. Which meant OIDC worked only
// for somebody who ALREADY had an account, while `.env.example`,
// `docker-compose.oidc.yml` and the whole point of the `guest` role
// (1700000014) all describe a first-time arrival landing as a guest. The docs
// were right and the rule was not.
//
// PocketBase sets `@request.context = "oauth2"` for the duration of that flow,
// and a normal API call cannot forge it — so creation is allowed in that
// context and nowhere else. An anonymous POST to /api/collections/users
// carries context "default" and stays refused, which is what keeps this from
// being self-registration by the back door.
//
// The gate this opens onto is still a wall: `zv_oauth2_provisioning.js` puts an
// unmapped arrival in `guest`, and every access rule in this database names the
// roles that may pass without naming that one. So the record exists, the person
// is authenticated, and they read nothing until a coordinator says otherwise.
// `EIERMANN_OIDC_ALLOWED_GROUPS` is the stronger setting for an instance whose
// provider holds far more people than the pigeon group: it refuses the
// registration outright.
//
// Written as an append rather than a rewritten literal because the rule this
// widens belongs to 1700000002 and may yet grow another clause there; the down
// migration removes exactly what the up added.

const OAUTH2 = '@request.context = "oauth2"';

migrate(
  (app) => {
    const users = app.findCollectionByNameOrId("users");
    const current = String(users.createRule || "");
    if (!current.includes(OAUTH2)) {
      users.createRule = OAUTH2 + " || (" + current + ")";
      app.save(users);
    }
  },
  (app) => {
    const users = app.findCollectionByNameOrId("users");
    const current = String(users.createRule || "");
    const prefix = OAUTH2 + " || (";
    if (current.startsWith(prefix) && current.endsWith(")")) {
      users.createRule = current.slice(prefix.length, -1);
      app.save(users);
    }
  },
);
