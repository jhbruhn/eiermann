/// <reference path="../pb_data/types.d.ts" />

// eiermann-30w.9 — `audit_entries` goes.
//
// ── What is being deleted, and why that is not a loss ──────────────────────
//
// This app kept its own audit log for one phase: `audit_entries` (1700000019),
// ten actions across four collections, each emitted from a hand-wired call site
// in the hook that performed the act. Everything else the app does — a Besuch,
// a finding, an area, a tour, an export, a sign-in — happened unobserved,
// because auditing a new collection meant remembering to write another call
// site.
//
// `audit_events` (1700000024) replaced it with zugvogel's machinery and one
// generic hook per verb, so auditing a collection is now a registry entry. By
// the time this migration runs, every act the old log recorded is recorded in
// the new one — asserted, not assumed: the rule suite checks the phase change,
// the delete, both directions across the protected line, the invitation, the
// role change, the end of somebody's access and the rhythm numbers against
// `audit_events` before the old call sites came out.
//
// ── The rows are NOT carried across ────────────────────────────────────────
//
// Decided in eiermann-30w.2 and stated here because this is where somebody will
// come looking. The two logs disagree structurally: one row per CHANGED FIELD
// there, one row per EVENT carrying a bag of changes here. Going the other way
// is the easy direction; coming this way means guessing which rows came from
// one save — they share an action, a target and a timestamp, and nothing
// recorded that they belonged together. A guess in an audit trail is worth less
// than an honest gap, and the honest gap is visible: the new log simply starts.
//
// The old rows are not destroyed silently either. This migration is the record
// that they existed and were dropped, and 1700000019 still stands above it
// describing what they held.
//
// ── Why a drop and not a rename ────────────────────────────────────────────
//
// A rename would keep the rows and make them unreadable: the client reads
// `audit_events`' columns, and nothing maps `field`/`from_value`/`to_value`
// onto `changes`. A table nobody can read, in a database where every other
// collection is swept for org scope and access rules, is a liability that looks
// like an asset.
//
// ── The down migration cannot bring the rows back ──────────────────────────
//
// It recreates the SHAPE, because a migration that cannot be reversed at all
// blocks `migrate down` for everything above it. What it cannot recreate is the
// content, and that is worth saying out loud rather than leaving somebody to
// discover after rolling back: the rows are gone with the table.

migrate(
  (app) => {
    app.delete(app.findCollectionByNameOrId("audit_entries"));
  },
  (app) => {
    const organisations = app.findCollectionByNameOrId("organisations");
    const users = app.findCollectionByNameOrId("users");

    // 1700000019's shape, empty. See the header: the rows are not recoverable
    // from here, and nothing in this app writes to this collection any more.
    app.save(
      new Collection({
        type: "base",
        name: "audit_entries",
        listRule: null,
        viewRule: null,
        createRule: null,
        updateRule: null,
        deleteRule: null,
        fields: [
          {
            name: "org",
            type: "relation",
            required: true,
            maxSelect: 1,
            collectionId: organisations.id,
            cascadeDelete: false,
          },
          { name: "action", type: "text", required: true, max: 64 },
          {
            name: "actor",
            type: "relation",
            required: false,
            maxSelect: 1,
            collectionId: users.id,
            cascadeDelete: false,
          },
          { name: "actor_label", type: "text", required: true, max: 200 },
          { name: "target_type", type: "text", required: false, max: 32 },
          { name: "target", type: "text", required: false, max: 64 },
          { name: "target_label", type: "text", required: false, max: 400 },
          { name: "field", type: "text", required: false, max: 64 },
          { name: "from_value", type: "text", required: false, max: 400 },
          { name: "to_value", type: "text", required: false, max: 400 },
          { name: "detail", type: "text", required: false, max: 1000 },
          { name: "created", type: "autodate", onCreate: true, onUpdate: false },
        ],
        indexes: [
          "CREATE INDEX idx_audit_org_created ON audit_entries (org, created DESC)",
          "CREATE INDEX idx_audit_target ON audit_entries (org, target, created DESC)",
        ],
      }),
    );
  },
);
