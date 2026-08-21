/// <reference path="../pb_data/types.d.ts" />

// eiermann-jbk — visits: one trip to one building.
//
// ── Why clients cannot create a visit ──────────────────────────────────────
//
// `createRule` is null on `visits`, and on `nest_checks` and `nest_eggs` in the
// next migration. The ONLY writer is POST /api/eiermann/visit, which writes the
// whole Besuch in one transaction.
//
// The alternative — seven individual REST writes as the volunteer works through
// the nests — fails in a way that is worse than an error. If the connection
// drops after the second nest, the database holds a visit in which five nests
// were not checked, and that is INDISTINGUISHABLE from five nests somebody
// deliberately did not touch. The data cannot say which, and no later screen
// can recover it. A partial visit must not be representable, so the only path
// that can create one is closed.
//
// This is also the answer to "the app has no offline mode": the visit form holds
// everything in memory and writes on completion, so in a cellar with no
// reception exactly ONE call fails, at a named point, with a retry button that
// is safe to press three times. The form survives losing reception. It does not
// survive the app being killed, and that is a stated limit rather than a bug.
//
// ── A skipped Besuch is a document, not an observation ─────────────────────
//
// `outcome = skipped` records a non-event: nobody was home, no key, building
// site. It deliberately does NOT enter the Rhythmus — treating "we could not get
// in" as "we looked and found nothing" would stretch the interval on a nest
// nobody has seen, which is the one direction the rhythm must never drift.

const MEMBER = '@request.auth.id != "" && @request.auth.is_active = true' +
  ' && @request.auth.role != null';

migrate(
  (app) => {
    const organisations = app.findCollectionByNameOrId("organisations");
    const spots = app.findCollectionByNameOrId("spots");
    const users = app.findCollectionByNameOrId("users");

    const visits = new Collection({
      type: "base",
      name: "visits",
      listRule: `${MEMBER} && org = @request.auth.org`,
      viewRule: `${MEMBER} && org = @request.auth.org`,
      // The transactional endpoint only. See the header.
      createRule: null,
      // A visit is an event: it happened the way it happened. The one thing
      // worth correcting afterwards is the free-text note, so that is the only
      // field an update may touch — everything else is guarded, which makes the
      // rule long and the intent unambiguous.
      updateRule:
        `${MEMBER} && org = @request.auth.org` +
        ' && @request.body.org:isset = false' +
        ' && @request.body.spot:isset = false' +
        ' && @request.body.visited_at:isset = false' +
        ' && @request.body.outcome:isset = false' +
        ' && @request.body.skip_reason:isset = false' +
        ' && @request.body.author:isset = false',
      // Deleting a visit would delete its checks, and the check history is the
      // Gedächtnis this app exists to be.
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
          name: "spot",
          type: "relation",
          required: true,
          collectionId: spots.id,
          maxSelect: 1,
          cascadeDelete: true,
        },
        { name: "visited_at", type: "date", required: true },
        {
          name: "outcome",
          type: "select",
          required: true,
          maxSelect: 1,
          values: ["checked", "skipped"],
        },
        {
          name: "skip_reason",
          type: "select",
          required: false,
          maxSelect: 1,
          values: [
            "nobody_there",
            "no_key",
            "access_blocked",
            "no_time",
            "construction",
            "other",
          ],
        },
        { name: "skip_note", type: "text", required: false, max: 500 },
        { name: "note", type: "text", required: false, max: 2000 },
        {
          name: "author",
          type: "relation",
          required: false,
          collectionId: users.id,
          maxSelect: 1,
          // A deleted account must not take the visits it recorded with it. The
          // relation goes empty and the history stands — which is why every
          // audit-shaped row also stores a NAME, not just this id.
          cascadeDelete: false,
        },
        { name: "author_name", type: "text", required: false, max: 200 },
        { name: "created", type: "autodate", onCreate: true, onUpdate: false },
        { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
      ],
      indexes: [
        // The Spot detail's history: this building's visits, newest first.
        "CREATE INDEX idx_visits_spot_when ON visits (spot, visited_at)",
        "CREATE INDEX idx_visits_org_when ON visits (org, visited_at)",
      ],
    });
    app.save(visits);

    // Photos that belong to no nest: the door, the new lock, the scaffolding.
    //
    // Client-writable, unlike everything else about a visit, and the reason is
    // a real constraint rather than an inconsistency: a file cannot ride inside
    // the JSON body of the transactional endpoint. Photos are therefore
    // attached AFTER the visit exists — which is also the better failure mode.
    // A photo upload that dies over a bad connection must not take a completed
    // visit with it; the checks are the record, the photo is an attachment.
    const visitPhotos = new Collection({
      type: "base",
      name: "visit_photos",
      listRule: `${MEMBER} && org = @request.auth.org`,
      viewRule: `${MEMBER} && org = @request.auth.org`,
      createRule: `${MEMBER} && @request.body.org = @request.auth.org`,
      updateRule:
        `${MEMBER} && org = @request.auth.org` +
        ' && @request.body.org:isset = false' +
        ' && @request.body.visit:isset = false',
      // A photo of the wrong door is worth deleting, and deleting it destroys
      // nothing else. This is the only part of a visit that any member may
      // remove.
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
          name: "visit",
          type: "relation",
          required: true,
          collectionId: visits.id,
          maxSelect: 1,
          cascadeDelete: true,
        },
        {
          name: "image",
          type: "file",
          required: true,
          maxSelect: 1,
          maxSize: 15728640,
          mimeTypes: ["image/jpeg", "image/png", "image/webp", "image/heic"],
          thumbs: ["120x120", "1200x1200"],
          protected: true,
        },
        { name: "caption", type: "text", required: false, max: 300 },
        { name: "created", type: "autodate", onCreate: true, onUpdate: false },
        { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
      ],
      indexes: ["CREATE INDEX idx_visit_photos_visit ON visit_photos (visit)"],
    });
    app.save(visitPhotos);
  },
  (app) => {
    app.delete(app.findCollectionByNameOrId("visit_photos"));
    app.delete(app.findCollectionByNameOrId("visits"));
  },
);
