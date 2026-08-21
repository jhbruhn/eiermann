/// <reference path="../pb_data/types.d.ts" />

// eiermann-jbk — nest_checks (the event) and nest_eggs (the current state).
//
// These two are the heart of the mechanics, and they are deliberately different
// kinds of thing:
//
//   * `nest_checks` is an EVENT and immutable. One row per nest per visit,
//     recording what was found and what was done. It is never edited and never
//     deleted, because it is the answer to "what was in this nest in April".
//   * `nest_eggs` is CURRENT STATE. One row per egg actually in the nest right
//     now, deleted when the egg leaves. It is a cache of the last check's
//     outcome, kept as rows so a screen can show "1 Kunstei seit 12 Tagen"
//     without replaying the history.
//
// Neither is client-writable at all. `nest_eggs` in particular: it is derived
// from the checks, and two writers of derived state drift — the version a client
// wrote and the version the endpoint computes. Then the nest shows one thing and
// the history says another, and there is no way to tell which is wrong.
//
// ── `state = partial` IS the Halbgelege ────────────────────────────────────
//
// A nest with two eggs where only one could be swapped. This is the second of
// the three field problems the app exists for: the half clutch is missed, the
// nest is revisited on the normal rhythm, and by then the remaining real egg has
// hatched. So `partial` does not just record a fact — it CREATES a follow-up
// (see the rhythm library), which enters the due list earlier than the ladder
// would and therefore wins the minimum.
//
// ── The arithmetic is the hook's, not the UI's ─────────────────────────────
//
// `*_after = *_before − removed + added` is enforced server-side. A client that
// can send inconsistent numbers can make a nest's egg count drift from its own
// history, and the drift is invisible: every individual screen looks plausible.

migrate(
  (app) => {
    const organisations = app.findCollectionByNameOrId("organisations");
    const visits = app.findCollectionByNameOrId("visits");
    const nests = app.findCollectionByNameOrId("nests");
    const users = app.findCollectionByNameOrId("users");

    const MEMBER = '@request.auth.id != "" && @request.auth.is_active = true' +
      ' && @request.auth.role != null';

    const checks = new Collection({
      type: "base",
      name: "nest_checks",
      listRule: `${MEMBER} && org = @request.auth.org`,
      viewRule: `${MEMBER} && org = @request.auth.org`,
      // The transactional endpoint only, in all three directions. An immutable
      // event with an update rule is not immutable.
      createRule: null,
      updateRule: null,
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
        {
          name: "nest",
          type: "relation",
          required: true,
          collectionId: nests.id,
          maxSelect: 1,
          cascadeDelete: true,
        },
        {
          name: "state",
          type: "select",
          required: true,
          maxSelect: 1,
          values: [
            // Swapped clean: every real egg replaced.
            "swapped",
            // The Halbgelege: a real egg is still in there afterwards.
            "partial",
            // Looked, nothing in it. The only state that advances the ladder.
            "empty",
            // Looked, decided not to act — an incubating bird, a nest too high.
            "untouched",
            // Could not reach it at all. Not an observation of the nest.
            "not_reachable",
            // The nest itself is no longer there. A finding about the building.
            "gone",
            // A protected species is sitting in it. No egg may be touched.
            "protected",
          ],
        },
        { name: "real_before", type: "number", required: false, onlyInt: true },
        { name: "dummy_before", type: "number", required: false, onlyInt: true },
        { name: "real_after", type: "number", required: false, onlyInt: true },
        { name: "dummy_after", type: "number", required: false, onlyInt: true },
        { name: "removed_real", type: "number", required: false, onlyInt: true },
        { name: "added_dummy", type: "number", required: false, onlyInt: true },
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
        // The snapshot, next to the id. An audit-shaped row that only holds a
        // relation tells the past wrongly the moment the account is renamed or
        // deleted — so the name at the time of the event is stored, and an id
        // without a label beside it is a bug.
        { name: "author_name", type: "text", required: false, max: 200 },
        { name: "checked_at", type: "date", required: true },
        { name: "created", type: "autodate", onCreate: true, onUpdate: false },
        { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
      ],
      indexes: [
        // "What happened to this nest, most recent first" — the single most
        // common read in the whole app.
        "CREATE INDEX idx_checks_nest_when ON nest_checks (nest, checked_at)",
        "CREATE INDEX idx_checks_visit ON nest_checks (visit)",
        "CREATE INDEX idx_checks_org_when ON nest_checks (org, checked_at)",
      ],
    });
    app.save(checks);

    const eggs = new Collection({
      type: "base",
      name: "nest_eggs",
      listRule: `${MEMBER} && org = @request.auth.org`,
      viewRule: `${MEMBER} && org = @request.auth.org`,
      // Derived state. Not writable by anybody but the endpoint.
      createRule: null,
      updateRule: null,
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
          name: "nest",
          type: "relation",
          required: true,
          collectionId: nests.id,
          maxSelect: 1,
          cascadeDelete: true,
        },
        // The position in the egg row on screen. Nests hold two or three eggs;
        // showing them in a stable order is what makes "the left one is real"
        // mean anything between two visits.
        //
        // NOT `required`, and not by oversight: PocketBase's required-validator
        // treats 0 as blank for a number, exactly as it treats false as blank
        // for a bool. Slot 0 is the first egg, so `required: true` rejects every
        // nest's first egg with "Cannot be blank" — which reads like a missing
        // field rather than a zero. Starting the slots at 1 would work too and
        // would put an off-by-one into every screen instead.
        { name: "slot_index", type: "number", required: false, onlyInt: true },
        {
          name: "kind",
          type: "select",
          required: true,
          maxSelect: 1,
          values: ["real", "dummy"],
        },
        // Not `created`: the date this EGG has been in the nest, which survives
        // the row being rewritten by a later check. It is what turns a dummy
        // into "1 Kunstei seit 12 Tagen" — and a dummy that has sat for months
        // is a nest the birds have given up on, which is worth seeing.
        { name: "since", type: "date", required: true },
        {
          name: "source_check",
          type: "relation",
          required: false,
          collectionId: checks.id,
          maxSelect: 1,
          // The check is the reason this row exists, but the check is immutable
          // and never deleted, so this never fires. Set to false rather than
          // true so that a future cascade cannot silently reach the eggs.
          cascadeDelete: false,
        },
        { name: "created", type: "autodate", onCreate: true, onUpdate: false },
        { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
      ],
      indexes: [
        "CREATE INDEX idx_eggs_nest ON nest_eggs (nest, slot_index)",
        "CREATE INDEX idx_eggs_org ON nest_eggs (org)",
      ],
    });
    app.save(eggs);
  },
  (app) => {
    app.delete(app.findCollectionByNameOrId("nest_eggs"));
    app.delete(app.findCollectionByNameOrId("nest_checks"));
  },
);
