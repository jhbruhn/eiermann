/// <reference path="../pb_data/types.d.ts" />

// eiermann-h7q.11 — organisations (single seed row) + users auth extensions.
//
// PocketBase ships a default `users` auth collection on first run. This EXTENDS
// it rather than recreating it: recreating loses the built-in email/password
// wiring, the verification and reset token plumbing, and the OAuth2 provider
// slots — none of which is worth rebuilding by hand.
//
// `organisations` is created first and seeded with ONE deterministic row, so
// `users.org` and every later collection can reference a stable id. The schema
// is multi-tenant from the start because retrofitting tenancy means touching
// every rule and every index; a second organisation is then a row, not a
// migration.
//
// Access rules are deliberately left at the superuser-only default here. The
// real private-by-default rules land in migration 002 — splitting them keeps
// this file about SHAPE and that one about ACCESS, so a rule change never has to
// be read as a schema change.
//
// ── A migration is a historical fact ────────────────────────────────────────
// This file will never be edited again once it has run anywhere. Fixing a field
// means a NEW migration; editing this one leaves every existing database in a
// state no migration describes. Same reason zugvogel ships hooks and Typst but
// NOT migrations: they are copied templates, renumbered per app, never shared.

const ORG_ID = "org00000default"; // 15-char stable id for the single launch org

migrate(
  (app) => {
    // ── organisations ─────────────────────────────────────────────────────
    const organisations = new Collection({
      type: "base",
      name: "organisations",
      // Rules null ⇒ superuser-only until migration 002.
      fields: [
        {
          name: "name",
          type: "text",
          required: true,
          presentable: true,
          max: 200,
        },
        { name: "contact_email", type: "email", required: false },
        { name: "contact_phone", type: "text", required: false, max: 50 },
        // THE only JSON field in this database, and it has exactly one reader:
        // the server's zv_org.js. `record.get()` on a JSON field hands JS a
        // types.JSONRaw byte array, so every property access is `undefined` and
        // code falls silently into its default — federfall shipped two inert
        // features that way (federfall-jumi). Carries the rhythm numbers, the
        // Nachkontrolle window and the report metadata, so an operator can
        // change them without a release.
        { name: "settings", type: "json", required: false, maxSize: 200000 },
        { name: "created", type: "autodate", onCreate: true, onUpdate: false },
        { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
      ],
    });
    app.save(organisations);

    // ── seed the single launch organisation ───────────────────────────────
    const org = new Record(organisations);
    org.set("id", ORG_ID);
    org.set("name", "Eiermann");
    app.save(org);

    // ── the instance's own name ───────────────────────────────────────────
    // PocketBase's default is "Acme", which is what /info reports as the
    // instance name and what the login screen shows. Set here rather than left
    // to the operator: a fresh instance greeting its team as Acme looks broken.
    // An operator who wants their own name changes it in the Admin UI, and that
    // wins — this only replaces the placeholder.
    const settings = app.settings();
    if (settings.meta.appName === "Acme") {
      settings.meta.appName = "Eiermann";
      app.save(settings);
    }

    // ── extend the default `users` auth collection ────────────────────────
    const users = app.findCollectionByNameOrId("users");

    // Two roles, not four. This is a small team where everybody does the field
    // work: a `member` walks the tour and records what they found, a
    // `coordinator` additionally decides the things that are hard to undo —
    // deleting a Spot, overriding a rhythm, taking a nest out of `protected`.
    //
    // NOT required, and that is deliberate: an OAuth2 account provisions itself
    // before anybody has decided what it may do, and a required role would make
    // that write fail. A row with no role is walled off by the access rules in
    // migration 002 — it can sign in and see nothing, which is the correct
    // state for somebody who has not been let in yet.
    users.fields.add(
      new SelectField({
        name: "role",
        required: false,
        maxSelect: 1,
        values: ["member", "coordinator"],
      }),
    );
    users.fields.add(
      new RelationField({
        name: "org",
        required: true,
        maxSelect: 1,
        collectionId: organisations.id,
        cascadeDelete: false,
      }),
    );
    // Deactivation, not deletion. A departed member's name still has to appear
    // on the visits they recorded — deleting the row would either cascade that
    // history away or leave it pointing at nothing.
    users.fields.add(new BoolField({ name: "is_active" }));
    users.fields.add(
      new RelationField({
        name: "invited_by",
        required: false,
        maxSelect: 1,
        collectionId: users.id, // self-reference: who let this person in
        cascadeDelete: false,
      }),
    );
    users.fields.add(
      new TextField({ name: "phone", required: false, max: 50 }),
    );

    // The auth rule, which is what makes deactivation take effect on a LIVE
    // token rather than at the next sign-in. PocketBase re-evaluates it on
    // every authenticated request, so flipping is_active ends the session in
    // flight — which is the whole point of having the flag.
    users.authRule = "is_active = true";
    // ...and the same for a token refresh, so a deactivated session cannot roll
    // itself forward.
    users.manageRule = null;

    app.save(users);
  },
  (app) => {
    // ── down: strip the added user fields, then drop organisations ────────
    const users = app.findCollectionByNameOrId("users");
    for (const name of ["role", "org", "is_active", "invited_by", "phone"]) {
      users.fields.removeByName(name);
    }
    users.authRule = "";
    app.save(users);

    const organisations = app.findCollectionByNameOrId("organisations");
    app.delete(organisations);
  },
);
