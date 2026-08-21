/// <reference path="../pb_data/types.d.ts" />

// eiermann-bmg.2 — nests: the centre of the mechanics.
//
// The Rhythmus ladder runs per nest. `nest_eggs` and `nest_checks` will hang off
// it, and the protected-species guard keys on it. Where `spots` is the centre of
// the product, this is the centre of the machinery.
//
// ── pin_x / pin_y are NORMALISED, 0…1, never pixels ────────────────────────
//
// A pin stored in pixels is a pin measured against one particular image at one
// particular size. A new photo, a different phone, a wider screen — any of them
// silently moves every nest on the map. Normalised coordinates survive all
// three, which is why the range is clamped here on the server rather than
// trusted from a client: a value of 1.7 puts a nest permanently off the photo,
// and nothing in the UI would ever show it again.
//
// ── `spot` is denormalised ON PURPOSE ──────────────────────────────────────
//
// A nest already reaches its Spot through its area. Duplicating it means the map
// query, the due-list and the urgency ranking read one table instead of joining
// two — and those three run on every screen. The price is that the copy can
// disagree with the area, so the client does not get to set it: a hook derives
// it from the area on every write.
//
// ── The three rhythm fields belong to the rhythm ───────────────────────────
//
// `interval_days`, `empty_streak` and `next_due_at` are the ladder's state. They
// are guarded against client writes at the rule level, because a client that can
// set them can make a nest look checked without anybody going there. That is the
// one lie this data model must not be able to tell, and it is worth repeating on
// every collection where it applies.
//
// ── species is a safety field, not a label ─────────────────────────────────
//
// See protected_guard.pb.js. `unknown` is a real state and never a silent
// assumption of "city pigeon": the app does not identify species, and an
// undetermined nest stays an open question in the Spot detail until a person
// decides. Anyone may mark a nest `protected`; only the coordination may take
// that back.

const MEMBER = '@request.auth.id != "" && @request.auth.is_active = true' +
  ' && @request.auth.role != null';

migrate(
  (app) => {
    const organisations = app.findCollectionByNameOrId("organisations");
    const spots = app.findCollectionByNameOrId("spots");
    const areas = app.findCollectionByNameOrId("areas");

    const nests = new Collection({
      type: "base",
      name: "nests",
      listRule: `${MEMBER} && org = @request.auth.org`,
      viewRule: `${MEMBER} && org = @request.auth.org`,
      createRule: `${MEMBER} && @request.body.org = @request.auth.org`,
      updateRule:
        `${MEMBER} && org = @request.auth.org` +
        ' && @request.body.org:isset = false' +
        // Both relations are pinned: re-parenting a nest would carry its whole
        // check history to another building.
        ' && @request.body.spot:isset = false' +
        ' && @request.body.area:isset = false' +
        // The rhythm's three fields. Written only by the rhythm library.
        ' && @request.body.interval_days:isset = false' +
        ' && @request.body.empty_streak:isset = false' +
        ' && @request.body.next_due_at:isset = false',
      // A nest is never deleted. `status = gone` records that it is no longer
      // there, which is a FINDING — a nest that disappeared is information about
      // the building. Deleting it would throw away every check ever made on it
      // and make the Spot's history claim the nest never existed. Not even the
      // coordination gets this route; there is no reason to want it.
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
        {
          name: "area",
          type: "relation",
          required: true,
          collectionId: areas.id,
          maxSelect: 1,
          cascadeDelete: true,
        },
        { name: "label", type: "text", required: true, min: 1, max: 40 },
        // What a pin cannot say: "auf dem Balken links", "hinter dem Rohr".
        // A photo shows where to look; this says what to look at.
        { name: "position_hint", type: "text", required: false, max: 300 },
        { name: "pin_x", type: "number", required: false, min: 0, max: 1 },
        { name: "pin_y", type: "number", required: false, min: 0, max: 1 },
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
          name: "species",
          type: "select",
          required: true,
          maxSelect: 1,
          values: ["feral_pigeon", "protected", "unknown"],
        },
        // The actual species name when somebody knows it — "Dohle", "Turmfalke".
        // Free text, and a view over the DISTINCT values recorded per org
        // becomes the picker later (bmg/3is): a curated list goes stale, holding
        // dead entries and missing the one the volunteer needs.
        { name: "species_label", type: "text", required: false, max: 120 },
        {
          name: "status",
          type: "select",
          required: true,
          maxSelect: 1,
          values: ["active", "gone"],
        },
        { name: "interval_days", type: "number", required: false, onlyInt: true },
        { name: "empty_streak", type: "number", required: false, onlyInt: true },
        { name: "next_due_at", type: "date", required: false },
        { name: "note", type: "text", required: false, max: 2000 },
        { name: "created", type: "autodate", onCreate: true, onUpdate: false },
        { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
      ],
      indexes: [
        // The nest list in the Spot detail, urgent first — the denormalised
        // `spot` is what lets this be one index rather than a join.
        "CREATE INDEX idx_nests_spot_due ON nests (spot, next_due_at)",
        // The photo map: every pin in one Bereich.
        "CREATE INDEX idx_nests_area ON nests (area)",
        // Rolling up nest due dates to the Spot, and the org-wide due list.
        "CREATE INDEX idx_nests_org_status_due ON nests (org, status, next_due_at)",
        // A label is unique within its Bereich. "N3" appearing twice in one
        // attic is a data-entry mistake that produces two histories for one
        // nest, and no screen can show that it happened.
        "CREATE UNIQUE INDEX idx_nests_area_label ON nests (area, label)",
      ],
    });
    app.save(nests);
  },
  (app) => {
    app.delete(app.findCollectionByNameOrId("nests"));
  },
);
