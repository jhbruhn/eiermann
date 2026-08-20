/// <reference path="../pb_data/types.d.ts" />

// eiermann-upa.2 — spot_contacts: the caretaker, the owner, the tenant.
//
// This collection plus `spots.access_note` IS the handover. Everything else the
// app records is about birds; this is the part that means a colleague can walk
// the route without ringing you first.
//
// ── Personal data, and a deliberate difference from federfall ──────────────
// These are named private individuals with phone numbers: third-party PII, and
// the app's only holding of it. federfall scrubs its equivalent on a retention
// cron, because a finder is somebody who called once and whose details stop
// being needed the moment the case closes.
//
// A caretaker is not that. Their details are needed for exactly as long as the
// Spot exists, and a scrub would delete the thing the collection is FOR. So
// there is no retention cron here — the data expires with the Spot, by cascade.
// That is a decision, not an omission, and it is why:
//
//  * the audit log must never copy these values (a copy in an append-only table
//    outlives the cascade that was supposed to remove them);
//  * `cascadeDelete` is TRUE, so deleting a Spot really does take its contacts
//    with it rather than leaving orphans pointing at nothing.

const MEMBER = '@request.auth.id != "" && @request.auth.is_active = true' +
  ' && @request.auth.role != null';
const COORDINATOR = '@request.auth.id != "" && @request.auth.is_active = true' +
  ' && @request.auth.role = "coordinator"';

migrate(
  (app) => {
    const organisations = app.findCollectionByNameOrId("organisations");
    const spots = app.findCollectionByNameOrId("spots");

    const contacts = new Collection({
      type: "base",
      name: "spot_contacts",
      // Readable by the whole org, like the Spot itself. Gating contacts below
      // the org line was considered and rejected: whoever is walking the route
      // tonight needs the caretaker's number, and "ask the coordinator for the
      // phone number" is the failure mode this app removes.
      listRule: `${MEMBER} && org = @request.auth.org`,
      viewRule: `${MEMBER} && org = @request.auth.org`,
      createRule: `${MEMBER} && @request.body.org = @request.auth.org`,
      updateRule:
        `${MEMBER} && org = @request.auth.org` +
        ' && @request.body.org:isset = false' +
        // The parent is frozen: an update rule resolves `spot` against the
        // STORED record, so a re-parenting write would be authorised against
        // the old Spot and land on the new one.
        ' && @request.body.spot:isset = false',
      // A contact CAN be deleted by any member, unlike a Spot: a wrong phone
      // number should be removable by whoever noticed, and there is no history
      // hanging off a contact to lose. Deleting the Spot is the destructive act,
      // and that stays the coordination's.
      deleteRule: `${MEMBER} && org = @request.auth.org`,
      fields: [
        {
          name: "org",
          type: "relation",
          required: true,
          maxSelect: 1,
          collectionId: organisations.id,
          cascadeDelete: false,
        },
        {
          name: "spot",
          type: "relation",
          required: true,
          maxSelect: 1,
          collectionId: spots.id,
          // See the header: these details expire WITH the Spot, and that is the
          // whole retention story.
          cascadeDelete: true,
        },
        {
          name: "role",
          type: "select",
          required: true,
          maxSelect: 1,
          values: ["owner", "management", "caretaker", "tenant", "other"],
        },
        {
          name: "name",
          type: "text",
          required: true,
          presentable: true,
          max: 200,
        },
        { name: "phone", type: "text", required: false, max: 50 },
        { name: "email", type: "email", required: false },
        { name: "note", type: "text", required: false, max: 1000 },
        // Who to try first. Not a unique index: two people can both be worth
        // calling, and a database that refuses to store that is a database
        // people work around by writing the second number into a note.
        { name: "is_primary", type: "bool", required: false },
        { name: "created", type: "autodate", onCreate: true, onUpdate: false },
        { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
      ],
      indexes: [
        "CREATE INDEX idx_spot_contacts_org_spot ON spot_contacts (org, spot)",
      ],
    });
    app.save(contacts);
  },
  (app) => {
    app.delete(app.findCollectionByNameOrId("spot_contacts"));
  },
);
