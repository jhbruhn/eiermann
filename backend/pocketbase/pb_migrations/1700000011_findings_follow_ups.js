/// <reference path="../pb_data/types.d.ts" />

// eiermann-jbk — findings (Funde) and follow_ups (Nachkontrollen).
//
// ── findings ───────────────────────────────────────────────────────────────
//
// What was found that is not an egg: a dead bird, a chick, another species, a
// change to the building. `species_label` is FREE TEXT on purpose, and later
// becomes a picker built as a view over the DISTINCT values actually recorded
// per org. A curated species list goes stale in both directions — it holds
// entries nobody has seen in years and lacks the one the volunteer is looking
// at. The price of growing vocabulary from use is that two spellings are two
// rows and nothing normalises behind your back; that is the cheaper problem.
//
// ── follow_ups, and why `due_at` is STORED ─────────────────────────────────
//
// A Nachkontrolle is a PLAN, and a plan is a fact about a decision somebody
// made. If `due_at` were derived from the org's current
// `half_clutch_return_days`, then changing that setting would retroactively move
// every outstanding follow-up — including ones already overdue, which would
// silently become on time. federfall learned this with vaccination dates.
//
// So the window is read once, at the moment the follow-up is created, and the
// resulting date is stored. Changing the setting affects the next Halbgelege,
// not the one already waiting.

migrate(
  (app) => {
    const organisations = app.findCollectionByNameOrId("organisations");
    const spots = app.findCollectionByNameOrId("spots");
    const nests = app.findCollectionByNameOrId("nests");
    const visits = app.findCollectionByNameOrId("visits");
    const checks = app.findCollectionByNameOrId("nest_checks");
    const users = app.findCollectionByNameOrId("users");

    const MEMBER = '@request.auth.id != "" && @request.auth.is_active = true' +
      ' && @request.auth.role != null';

    const findings = new Collection({
      type: "base",
      name: "findings",
      listRule: `${MEMBER} && org = @request.auth.org`,
      viewRule: `${MEMBER} && org = @request.auth.org`,
      // Part of the visit transaction, like the checks.
      createRule: null,
      // The note and the species label are the two things somebody realises
      // afterwards — "that was a Dohle, not a Ringeltaube". The rest is the
      // event.
      updateRule:
        `${MEMBER} && org = @request.auth.org` +
        ' && @request.body.org:isset = false' +
        ' && @request.body.visit:isset = false' +
        ' && @request.body.spot:isset = false' +
        ' && @request.body.nest:isset = false' +
        ' && @request.body.kind:isset = false',
      deleteRule: null,
      fields: [
        {
          name: "org",
          type: "relation",
          required: true,
          collectionId: organisations.id,
          maxSelect: 1,
          cascadeDelete: false,
        },
        {
          name: "visit",
          type: "relation",
          required: true,
          collectionId: visits.id,
          maxSelect: 1,
          cascadeDelete: true,
        },
        // Denormalised from the visit, for the same reason nests carry `spot`:
        // "every finding at this building" is a Spot-detail read and must not
        // need a join.
        {
          name: "spot",
          type: "relation",
          required: true,
          collectionId: spots.id,
          maxSelect: 1,
          cascadeDelete: true,
        },
        // Optional: a dead bird on the floor belongs to no nest.
        {
          name: "nest",
          type: "relation",
          required: false,
          collectionId: nests.id,
          maxSelect: 1,
          cascadeDelete: true,
        },
        {
          name: "kind",
          type: "select",
          required: true,
          maxSelect: 1,
          values: ["dead_bird", "chick", "other_species", "site_change"],
        },
        { name: "count", type: "number", required: false, onlyInt: true },
        { name: "species_label", type: "text", required: false, max: 120 },
        { name: "note", type: "text", required: false, max: 2000 },
        {
          name: "photo",
          type: "file",
          required: false,
          maxSelect: 1,
          maxSize: 10485760,
          mimeTypes: ["image/jpeg", "image/png", "image/webp", "image/heic"],
          thumbs: ["100x100", "600x600"],
          protected: true,
        },
        {
          name: "author",
          type: "relation",
          required: false,
          collectionId: users.id,
          maxSelect: 1,
          cascadeDelete: false,
        },
        { name: "author_name", type: "text", required: false, max: 200 },
        { name: "found_at", type: "date", required: true },
        { name: "created", type: "autodate", onCreate: true, onUpdate: false },
        { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
      ],
      indexes: [
        "CREATE INDEX idx_findings_spot_when ON findings (spot, found_at)",
        "CREATE INDEX idx_findings_visit ON findings (visit)",
        // The species_labels view reads this: what has actually been recorded,
        // per org.
        "CREATE INDEX idx_findings_org_species ON findings (org, species_label)",
      ],
    });
    app.save(findings);

    const followUps = new Collection({
      type: "base",
      name: "follow_ups",
      listRule: `${MEMBER} && org = @request.auth.org`,
      viewRule: `${MEMBER} && org = @request.auth.org`,
      // A member may create a MANUAL follow-up — "check that lock again next
      // week" is a legitimate note-to-the-team. `half_clutch` is the rhythm's to
      // create, and pinning the reason in the rule is what keeps a hand-made row
      // from claiming to be a Halbgelege the system never saw.
      createRule:
        `${MEMBER} && @request.body.org = @request.auth.org` +
        ' && @request.body.reason = "manual"' +
        ' && @request.body.created_from_check:isset = false' +
        ' && @request.body.resolved_at:isset = false' +
        ' && @request.body.resolved_by_check:isset = false',
      // The note and the due date of a manual follow-up can be adjusted. What
      // cannot: its reason, its origin, and its resolution — a follow-up marked
      // resolved by hand is a Nachkontrolle nobody carried out.
      updateRule:
        `${MEMBER} && org = @request.auth.org` +
        ' && @request.body.org:isset = false' +
        ' && @request.body.spot:isset = false' +
        ' && @request.body.nest:isset = false' +
        ' && @request.body.reason:isset = false' +
        ' && @request.body.created_from_check:isset = false' +
        ' && @request.body.resolved_at:isset = false' +
        ' && @request.body.resolved_by_check:isset = false',
      // A manual reminder that turned out to be unnecessary is worth removing,
      // and it carries no history. A half-clutch follow-up is not deletable —
      // that distinction cannot be expressed in a rule, so the hook enforces it
      // (app_follow_up.js).
      deleteRule: `${MEMBER} && org = @request.auth.org`,
      fields: [
        {
          name: "org",
          type: "relation",
          required: true,
          collectionId: organisations.id,
          maxSelect: 1,
          cascadeDelete: false,
        },
        {
          name: "spot",
          type: "relation",
          required: true,
          collectionId: spots.id,
          maxSelect: 1,
          cascadeDelete: true,
        },
        {
          name: "nest",
          type: "relation",
          required: false,
          collectionId: nests.id,
          maxSelect: 1,
          cascadeDelete: true,
        },
        // Stored, never derived. See the header.
        { name: "due_at", type: "date", required: true },
        {
          name: "reason",
          type: "select",
          required: true,
          maxSelect: 1,
          values: ["half_clutch", "manual"],
        },
        { name: "note", type: "text", required: false, max: 2000 },
        {
          name: "created_from_check",
          type: "relation",
          required: false,
          collectionId: checks.id,
          maxSelect: 1,
          cascadeDelete: false,
        },
        { name: "resolved_at", type: "date", required: false },
        {
          name: "resolved_by_check",
          type: "relation",
          required: false,
          collectionId: checks.id,
          maxSelect: 1,
          cascadeDelete: false,
        },
        { name: "created", type: "autodate", onCreate: true, onUpdate: false },
        { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
      ],
      indexes: [
        // The open ones, by date: this feeds spot.next_due_at and the dashboard.
        // `resolved_at` leads the tail so an index scan can skip the resolved.
        "CREATE INDEX idx_follow_ups_open ON follow_ups (org, resolved_at, due_at)",
        "CREATE INDEX idx_follow_ups_spot ON follow_ups (spot, resolved_at)",
        "CREATE INDEX idx_follow_ups_nest ON follow_ups (nest, resolved_at)",
      ],
    });
    app.save(followUps);
  },
  (app) => {
    app.delete(app.findCollectionByNameOrId("follow_ups"));
    app.delete(app.findCollectionByNameOrId("findings"));
  },
);
