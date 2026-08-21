/// <reference path="../pb_data/types.d.ts" />

// eiermann-jbk — add `request_hash` to idempotency_keys.
//
// Its own migration rather than an edit to 1700000003, because that one has been
// applied. A migration is a historical fact: editing an applied file produces a
// database that no other machine can reach, and the divergence shows up as
// something else entirely weeks later.
//
// ── What the field is for ──────────────────────────────────────────────────
//
// An Idempotency-Key makes a retry safe by returning the stored response instead
// of writing twice. But the key alone does not say WHICH request it stands for,
// so a key replayed with a DIFFERENT body would be answered with the first
// request's result.
//
// That failure is silent and expensive: a client that forgets to regenerate the
// key between two visits gets the first visit's response for the second one. The
// second visit is never written, the app reports success, and the nests it
// contained quietly keep their old dates. Nothing errors anywhere, and the
// missing visit looks exactly like a visit nobody made.
//
// With the fingerprint stored, the mismatch is a 409 that names the problem.

migrate(
  (app) => {
    const collection = app.findCollectionByNameOrId("idempotency_keys");
    collection.fields.add(
      new TextField({
        name: "request_hash",
        required: false,
        max: 80,
      }),
    );
    app.save(collection);
  },
  (app) => {
    const collection = app.findCollectionByNameOrId("idempotency_keys");
    collection.fields.removeByName("request_hash");
    app.save(collection);
  },
);
