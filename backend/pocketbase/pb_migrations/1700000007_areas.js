/// <reference path="../pb_data/types.d.ts" />

// eiermann-bmg.1 — areas: a Bereich, a named part of a building.
//
// A Bereich exists for one reason: it carries the overview PHOTO, and the photo
// carries the nest pins. That is the whole visual model — you look at a picture
// of the attic and see where the nests are. So the photo is not decoration on an
// area, it is the thing an area is for, and everything else here supports it.
//
// ── The photo replacement problem ──────────────────────────────────────────
//
// Pins are normalised coordinates on a photo (see nests). Replace the photo and
// every pin now points at the wrong place on a different image — the beam that
// was centre-left is now bottom-right, and nobody notices until somebody is
// standing in an attic looking at the wrong rafter.
//
// So a replacement is not a field update, it is a REVIEW PASS:
//
//   * the outgoing photo moves to `previous_photo`, so old and new can be seen
//     side by side; without it a reviewer is guessing at what moved;
//   * `pins_need_review` goes true, and the Bereich announces itself as
//     unreliable until every pin has been confirmed or moved once;
//   * when the pass finishes, `previous_photo` is deleted.
//
// `previous_photo` holds EXACTLY ONE generation. A history of photos sounds
// harmless and is not: it is a stack of pictures of somebody's private property
// with no purpose left, and storage of personal data has to justify itself
// continuously, not once.
//
// The flow itself is a hook (bmg.5); this migration only makes the states
// representable.

const MEMBER = '@request.auth.id != "" && @request.auth.is_active = true' +
  ' && @request.auth.role != null';
const COORDINATOR = '@request.auth.id != "" && @request.auth.is_active = true' +
  ' && @request.auth.role = "coordinator"';

migrate(
  (app) => {
    const organisations = app.findCollectionByNameOrId("organisations");
    const spots = app.findCollectionByNameOrId("spots");

    const areas = new Collection({
      type: "base",
      name: "areas",
      listRule: `${MEMBER} && org = @request.auth.org`,
      viewRule: `${MEMBER} && org = @request.auth.org`,
      createRule: `${MEMBER} && @request.body.org = @request.auth.org`,
      // `spot` is pinned on update as well as `org`. Moving a Bereich to another
      // building would take its nests — and their whole check history — with it,
      // and an update rule resolves a plain field reference against the STORED
      // record, so it would be authorised against the old Spot.
      updateRule:
        `${MEMBER} && org = @request.auth.org` +
        ' && @request.body.org:isset = false' +
        ' && @request.body.spot:isset = false',
      // Deleting a Bereich deletes its nests, and with them every check ever
      // recorded on them. Same reasoning as a Spot: the destructive route is the
      // coordination's.
      deleteRule: `${COORDINATOR} && org = @request.auth.org`,
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
          // The Spot is the dossier; a Bereich has no meaning without it.
          cascadeDelete: true,
        },
        { name: "name", type: "text", required: true, min: 1, max: 120 },
        {
          name: "photo",
          type: "file",
          required: false,
          maxSelect: 1,
          maxSize: 15728640,
          mimeTypes: ["image/jpeg", "image/png", "image/webp", "image/heic"],
          // 1200px wide is the pin editor's working size; the small thumb is the
          // Spot-detail list.
          thumbs: ["120x120", "1200x1200"],
          // Protected: this is the inside of somebody's building. Serving it
          // needs a short-lived file token issued to a caller who may read the
          // record.
          protected: true,
        },
        {
          name: "previous_photo",
          type: "file",
          required: false,
          maxSelect: 1,
          maxSize: 15728640,
          mimeTypes: ["image/jpeg", "image/png", "image/webp", "image/heic"],
          thumbs: ["120x120", "1200x1200"],
          protected: true,
        },
        { name: "photo_taken_at", type: "date", required: false },
        // Not `required`, because false is the resting state and PocketBase
        // treats a required bool as "must be true".
        { name: "pins_need_review", type: "bool", required: false },
        // Bereiche have a physical order a volunteer walks in — ground floor,
        // then the attic. Alphabetical would scatter that.
        { name: "sort_index", type: "number", required: false, onlyInt: true },
        { name: "note", type: "text", required: false, max: 2000 },
        { name: "created", type: "autodate", onCreate: true, onUpdate: false },
        { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
      ],
      indexes: [
        // Every read of an area starts from its Spot: the Spot detail lists
        // them, in walking order.
        "CREATE INDEX idx_areas_spot_sort ON areas (spot, sort_index)",
        "CREATE INDEX idx_areas_org ON areas (org)",
      ],
    });
    app.save(areas);
  },
  (app) => {
    app.delete(app.findCollectionByNameOrId("areas"));
  },
);
