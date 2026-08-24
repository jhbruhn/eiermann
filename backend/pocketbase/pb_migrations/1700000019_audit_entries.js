/// <reference path="../pb_data/types.d.ts" />

// eiermann-uwd.3 — audit_entries: who changed what, and what it used to say.
//
// ── What this is for ───────────────────────────────────────────────────────
//
// A handful of acts in this app are hard to undo and easy to do quietly:
// releasing a protected nest (which re-enables egg removal on it — the one
// action here that can be illegal), closing a building, granting the
// coordination, ending somebody's access, changing the numbers every due date
// comes out of. None of them leaves a trace in the record it changed: a Spot
// holds its CURRENT phase, a user their CURRENT role. The state is the only
// thing stored, so "since when, and who decided" has no answer at all.
//
// ── Append-only, and that is the schema, not a convention ──────────────────
//
// `createRule`, `updateRule` and `deleteRule` are all null: superuser-only, the
// strongest statement PocketBase offers. Nothing with an API token can write
// here, edit a row, or remove one — including the coordination, whose own acts
// this records. The hooks write through `app.save`, which does not go through
// the access rules at all, so the ONLY way a row appears is a hook deciding it
// should.
//
// Read is the coordination's alone. A member seeing who demoted whom is a
// different product; the point of this table is accountability upwards.
//
// ── Everything a reader sees is TEXT captured at emit time ─────────────────
//
// `actor_label`, `target_label`, `from_value` and `to_value` are SNAPSHOTS.
// This is the same rule every audit-shaped row in this database already
// follows (`visits.author_name`, `tour_runs.tour_name`), and here it is
// load-bearing twice over:
//
//   * the target may be renamed — and then a live lookup makes the row describe
//     the past wrongly, saying somebody closed "Bahnhofstraße 12" when what
//     they closed was called "Speicher Nord" that day;
//   * the target may be DELETED — a Spot, a nest, an account — and then a
//     relation dangles or, far worse, cascades.
//
// Which is why `target` is a plain TEXT id and not a relation. A relation here
// would have to choose between cascading (deleting a Spot would erase the
// record of it being deleted) and not cascading (a dangling pointer). Text is
// neither: it is a note of which row this was about, next to what that row was
// called. The id is there so a reader can still navigate when the target lives;
// the label is there so the row still means something when it does not.
//
// `actor` IS a relation, because an account is never deleted in this app
// (`users.deleteRule` is null — deactivation is the retirement path), and the
// snapshot sits beside it anyway.
//
// ── One row per CHANGED FIELD ──────────────────────────────────────────────
//
// Rather than one row per action carrying a bag of changes. Two reasons, and
// the first is structural: a bag would have to be a JSON field, and this
// database has exactly two of those on purpose — a JSON field hands the JSVM a
// `types.JSONRaw` byte array whose every property reads `undefined`, which is
// how federfall shipped two inert features. The rule suite sweeps for a third.
//
// The second is that the log reads better this way. "Rita changed the phase
// from active to closed" is the sentence somebody wants; a row that says
// "Rita changed a Spot" and makes the reader open something is a log people
// stop reading.
//
// `field`, `from_value` and `to_value` carry WIRE values — `closed`,
// `coordinator`, `7`. Never German. A hook does not know which language the
// reader speaks, and this table outlives any sentence written into it; the
// client maps them, exactly as it maps a refusal code. `eiermann-uwd.4` is the
// test that no recorded field can render as its raw column name.

const COORDINATOR = '@request.auth.id != "" && @request.auth.is_active = true' +
  ' && @request.auth.role = "coordinator"';

migrate(
  (app) => {
    const organisations = app.findCollectionByNameOrId("organisations");
    const users = app.findCollectionByNameOrId("users");

    const audit = new Collection({
      type: "base",
      name: "audit_entries",
      // Read: the coordination, in its own organisation. Write: nobody with a
      // token, ever — see the header. Null is not an oversight here, it is the
      // append-only guarantee.
      listRule: `${COORDINATOR} && org = @request.auth.org`,
      viewRule: `${COORDINATOR} && org = @request.auth.org`,
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
        // The wire value from this log's own ACTIONS registry, e.g.
        // `spot_phase_changed`. Renaming one is a wire change: the client maps
        // it to an ARB key, and the rows already written keep the old spelling.
        //
        // The registry lived in a hook that eiermann-30w.9 deleted along with
        // this collection. The filename is out of the comment rather than the
        // comment out of the file, because a migration is a historical fact and
        // its BEHAVIOUR is what may not change — but a design record whose grep
        // finds nothing is the hole the rule suite's dangling-pointer sweep
        // exists for, and it reads migrations.
        { name: "action", type: "text", required: true, max: 64 },
        {
          name: "actor",
          type: "relation",
          required: false,
          maxSelect: 1,
          collectionId: users.id,
          cascadeDelete: false,
        },
        // Who they were CALLED at the time. An id without a label beside it is
        // a bug in this app: the account may be renamed, and then the row
        // describes the past wrongly.
        { name: "actor_label", type: "text", required: true, max: 200 },
        // `spot`, `nest`, `user`, `org` — a wire value, so the client can pick
        // an icon and a route without parsing the action.
        { name: "target_type", type: "text", required: false, max: 32 },
        // TEXT, not a relation. See the header: a relation would have to choose
        // between cascading (deleting a Spot erases the record of the deletion)
        // and dangling.
        { name: "target", type: "text", required: false, max: 64 },
        { name: "target_label", type: "text", required: false, max: 400 },
        // The column that changed, from the FIELDS registry — `phase`, `role`,
        // `base_interval_days`. Empty for an action that is not a field change,
        // like an export.
        { name: "field", type: "text", required: false, max: 64 },
        // Wire values, never sentences. Empty means "there was none" — a nest
        // that had no species recorded before, a Spot with no close reason.
        { name: "from_value", type: "text", required: false, max: 400 },
        { name: "to_value", type: "text", required: false, max: 400 },
        // Free context the reader needs and the fields above cannot carry: the
        // reason typed into a close dialog, the period an export covered. Also
        // a wire-ish value where it is one; German only where a HUMAN typed the
        // German, which is the one case a hook may store prose because it is
        // quoting rather than speaking.
        { name: "detail", type: "text", required: false, max: 1000 },
        { name: "created", type: "autodate", onCreate: true, onUpdate: false },
      ],
      indexes: [
        // The one query this table has: the org's log, newest first, paged by
        // keyset. `?page=` over a table that grows while being read skips and
        // duplicates rows, and an audit log that silently omits an entry is
        // worse than no audit log.
        "CREATE INDEX idx_audit_org_created ON audit_entries (org, created DESC)",
        // Narrowing to one building or one account, which is the second thing
        // anybody asks of a log.
        "CREATE INDEX idx_audit_target ON audit_entries (org, target, created DESC)",
      ],
    });
    app.save(audit);
  },
  (app) => {
    app.delete(app.findCollectionByNameOrId("audit_entries"));
  },
);
