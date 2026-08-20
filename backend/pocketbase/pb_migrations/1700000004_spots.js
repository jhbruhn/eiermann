/// <reference path="../pb_data/types.d.ts" />

// eiermann-upa.1 — spots: one building, one address, one dossier.
//
// `spots` is the CENTRE of the product. Areas, nests, contacts, visits,
// findings, follow-ups and tour stops all hang off it, and the Spot detail is
// the screen the work actually happens on — the map is only the way in.
//
// ── Two decisions worth reading before changing a field ────────────────────
//
// `prospect_stage` STAYS SET after the Spot goes active. It is tempting to
// clear it as a transient, but how permission was obtained — who was spoken to,
// who refused first — is part of the dossier. Losing it is how the same
// conversation gets had twice, which is precisely the handover pain this app
// exists to remove.
//
// `next_due_at` is DERIVED BUT STORED. Computing it per request would mean the
// map cannot colour itself in one query, and the map is the entry point for
// every round. Only the rhythm library writes it — never a client, never a
// form. It is nullable because a prospect and a closed Spot are not due at all.

const MEMBER = '@request.auth.id != "" && @request.auth.is_active = true' +
  ' && @request.auth.role != null';
const COORDINATOR = '@request.auth.id != "" && @request.auth.is_active = true' +
  ' && @request.auth.role = "coordinator"';

migrate(
  (app) => {
    const organisations = app.findCollectionByNameOrId("organisations");

    const spots = new Collection({
      type: "base",
      name: "spots",
      // Everything in the org is visible to everybody in the org. This is a
      // small team walking a shared route; a Spot only one person can see is a
      // Spot that gets visited twice or not at all.
      listRule: `${MEMBER} && org = @request.auth.org`,
      viewRule: `${MEMBER} && org = @request.auth.org`,
      // Any member may add a building they walked past. The org is pinned to
      // the caller's own — that is the one write that could cross tenancy.
      createRule: `${MEMBER} && @request.body.org = @request.auth.org`,
      // Any member may edit. `org` is pinned on update as well: an update rule
      // resolves field references against the STORED record, so without the
      // guard the write would be authorised against the old org and land in the
      // new one.
      //
      // `next_due_at` is guarded too. It is the rhythm's output, and a client
      // that can set it can make a nest look done without visiting it — the one
      // lie this data model must not be able to tell.
      updateRule:
        `${MEMBER} && org = @request.auth.org` +
        ' && @request.body.org:isset = false' +
        ' && @request.body.next_due_at:isset = false',
      // Deleting a Spot destroys its whole dossier: the Erkundung history, every
      // visit, every check. Closing it keeps all of that and is what somebody
      // actually wants nine times out of ten — so the destructive route is the
      // coordination's.
      deleteRule: `${COORDINATOR} && org = @request.auth.org`,
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
          name: "name",
          type: "text",
          required: true,
          presentable: true,
          max: 200,
        },
        { name: "street", type: "text", required: false, max: 200 },
        { name: "postal_code", type: "text", required: false, max: 20 },
        { name: "city", type: "text", required: false, max: 120 },
        // PocketBase has no null for a geoPoint: clearing one stores
        // {lon: 0, lat: 0}. Read literally that is a real place in the Gulf of
        // Guinea, so every un-pinned Spot would render as a plausible marker in
        // the Atlantic. GeoPoint.fromPb treats the pair as null; nothing else
        // may read this field raw.
        { name: "geo", type: "geoPoint", required: false },
        // Whether a person confirmed the pin, as opposed to a geocoder guessing
        // it from the address. A guessed pin on the wrong side of a courtyard
        // sends somebody to the wrong door, and the difference has to be
        // visible on the map.
        { name: "geo_confirmed", type: "bool", required: false },
        {
          name: "phase",
          type: "select",
          required: true,
          maxSelect: 1,
          values: ["prospect", "active", "paused", "closed"],
        },
        {
          name: "prospect_stage",
          type: "select",
          required: false,
          maxSelect: 1,
          values: [
            "untouched",
            "tenant_spoken",
            "owner_spoken",
            "permitted",
            "refused",
          ],
        },
        // Optional auto-resume date, for the reasons a Spot goes quiet on a
        // schedule: scaffolding, winter, a caretaker away.
        { name: "paused_until", type: "date", required: false },
        { name: "pause_reason", type: "text", required: false, max: 300 },
        {
          name: "closed_reason",
          type: "select",
          required: false,
          maxSelect: 1,
          values: [
            "netted",
            "permission_withdrawn",
            "building_gone",
            "no_pigeons",
          ],
        },
        { name: "closed_at", type: "date", required: false },
        // The "how do I get in" text. This is the single most valuable field for
        // a handover and the reason the app beats a chat log: which bell, which
        // key, which caretaker, which hours.
        { name: "access_note", type: "text", required: false, max: 2000 },
        { name: "note", type: "text", required: false, max: 2000 },
        {
          name: "facade_photo",
          type: "file",
          required: false,
          maxSelect: 1,
          maxSize: 10485760,
          mimeTypes: ["image/jpeg", "image/png", "image/webp", "image/heic"],
          thumbs: ["100x100", "600x600"],
          // Protected: a facade photo shows somebody's home. Serving it needs a
          // short-lived file token issued for a caller who may read the record.
          protected: true,
        },
        { name: "next_due_at", type: "date", required: false },
        { name: "created", type: "autodate", onCreate: true, onUpdate: false },
        { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
      ],
      indexes: [
        // Every list and every map query starts from the org, so it leads every
        // index. A filter that cannot use one is a table scan on the only table
        // that grows without bound.
        "CREATE INDEX idx_spots_org_phase ON spots (org, phase)",
        "CREATE INDEX idx_spots_org_due ON spots (org, next_due_at)",
        // The Spot list pages by keyset on `created`, and a keyset needs the
        // tiebreaker column in the index too.
        "CREATE INDEX idx_spots_org_created ON spots (org, created, id)",
      ],
    });
    app.save(spots);
  },
  (app) => {
    app.delete(app.findCollectionByNameOrId("spots"));
  },
);
