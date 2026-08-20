/// <reference path="../pb_data/types.d.ts" />

// eiermann-h7q.12 — the access-rule skeleton.
//
// Split from migration 001 so a rule change is never read as a schema change.
// This file is the security model for everything that exists so far, and the
// shape every later collection copies.
//
// ── The four properties every rule in this database has ────────────────────
//
// 1. NEVER ANONYMOUS. Every rule opens with `@request.auth.id != ""`. Not one
//    collection, not even a reference list, is readable without signing in.
//
// 2. ALWAYS `is_active`. Repeated in every rule even though it is already the
//    collection's `authRule`. The repetition is not redundant: `authRule` gates
//    authentication, and repeating the check in the ACCESS rules is what makes
//    deactivation revoke a live token's reach on the very next request rather
//    than at its next sign-in.
//
// 3. A ROLE-LESS ACCOUNT SEES NOTHING. `role != null` is required to read
//    anything. An OAuth2 account provisions itself before anybody has decided
//    what it may do, so that state must exist — and it must be a wall, not a
//    default level of access.
//
// 4. TENANCY IS A PROPERTY OF THE STORED ROW, never of the request:
//    `org = @request.auth.org`, compared against what is already in the
//    database. Never a lookup against the request body, which the caller
//    controls.
//
// ── And the one thing rules CANNOT do ──────────────────────────────────────
// A rule cannot stop a user editing their OWN privilege fields. `users`
// necessarily lets somebody update their own row (name, phone, password), and
// `role` / `org` / `is_active` sit on that same row — so a plain PATCH would be
// a privilege escalation. federfall's rules had exactly this hole, closed only
// by a hook. The `:isset = false` guards below are the rule-level half; the
// hook in pb_hooks is the half that actually holds, because a guard listing
// fields by name is a guard somebody forgets to extend.

// Signed in, active, and let in. The opening of every rule in this database.
const MEMBER = '@request.auth.id != "" && @request.auth.is_active = true' +
  ' && @request.auth.role != null';

// The same, plus the role that decides things that are hard to undo.
const COORDINATOR = '@request.auth.id != "" && @request.auth.is_active = true' +
  ' && @request.auth.role = "coordinator"';

migrate(
  (app) => {
    // ── organisations ─────────────────────────────────────────────────────
    // Readable by its own members so the app can show the instance name and
    // read the rhythm settings. Writable by nobody through the API: the
    // settings JSON has exactly one reader (zv_org.js) and changing it is an
    // operator act through the dashboard, not an in-app one. Making it
    // coordinator-writable would put the only JSON field in the database behind
    // a form, which is how a malformed settings blob silently disables every
    // org-configurable window.
    const organisations = app.findCollectionByNameOrId("organisations");
    organisations.listRule = `${MEMBER} && id = @request.auth.org`;
    organisations.viewRule = `${MEMBER} && id = @request.auth.org`;
    organisations.createRule = null;
    organisations.updateRule = null;
    organisations.deleteRule = null;
    app.save(organisations);

    // ── users ─────────────────────────────────────────────────────────────
    const users = app.findCollectionByNameOrId("users");

    // The whole team is visible to the whole team: a visit names its author, a
    // tour names who is running it, and a name that cannot be resolved is worse
    // than no name. Scoped to the org, and only to active accounts' own org.
    users.listRule = `${MEMBER} && org = @request.auth.org`;
    users.viewRule = `${MEMBER} && org = @request.auth.org`;

    // Only the coordination adds people. There is no self-registration: an
    // account exists because somebody decided it should.
    //
    // The org is pinned to the creator's own — without this a coordinator could
    // create a user in another organisation, which is the one write that
    // crosses the tenancy line.
    users.createRule = `${COORDINATOR} && @request.body.org = @request.auth.org`;

    // Two ways to update a user: it is you, or you are the coordination.
    //
    // The `:isset = false` guards are what make the self-update safe. They are
    // the rule-level half of the privilege-escalation defence — the hook is the
    // other half, and the one that holds when somebody adds a fifth privilege
    // field and forgets this line.
    //
    // `org` is guarded on BOTH paths, including the coordinator's: moving a user
    // between organisations is not an edit, it is a re-tenanting, and it has no
    // legitimate in-app trigger.
    users.updateRule =
      `(${MEMBER} && id = @request.auth.id` +
      ' && @request.body.role:isset = false' +
      ' && @request.body.org:isset = false' +
      ' && @request.body.is_active:isset = false' +
      ' && @request.body.verified:isset = false)' +
      ` || (${COORDINATOR} && org = @request.auth.org` +
      ' && @request.body.org:isset = false)';

    // Nobody is deleted through the API. `is_active = false` is the retirement
    // path, because a departed member's name still has to appear on the visits
    // they recorded — deleting the row would either cascade that history away or
    // leave it pointing at nothing.
    users.deleteRule = null;

    app.save(users);
  },
  (app) => {
    for (const name of ["organisations", "users"]) {
      const collection = app.findCollectionByNameOrId(name);
      collection.listRule = null;
      collection.viewRule = null;
      collection.createRule = null;
      collection.updateRule = null;
      collection.deleteRule = null;
      app.save(collection);
    }
  },
);
