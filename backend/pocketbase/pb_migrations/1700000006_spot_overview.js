/// <reference path="../pb_data/types.d.ts" />

// eiermann-upa.12 — spot_overview: the Spot list and the map read ONE query.
//
// A list screen that fires one query per row is the thing that makes an app feel
// broken on a phone in a stairwell. So everything the map pin and the list row
// need — the address, the phase, the pin, the contact count, the due date and an
// urgency rank to sort and colour by — is one view.
//
// ── Why a view and not a client-side join ──────────────────────────────────
// The alternative is fetching spots and then contacts and then counting in
// Dart, which is three round trips and a rebuild storm. A view is one.
//
// ── Three PocketBase traps this SQL is written around ──────────────────────
//
// 1. A view collection's rules apply, but its columns are typed by inference.
//    A computed column is reported as type `json`, which means `getString()`
//    hands back a value WITH QUOTES on it. So every computed column here is
//    either a plain integer or is read through a converter that tolerates it —
//    never interpolated straight into a label.
// 2. `id` must be the first column and must be a real row id. A view without it
//    cannot be read through the records API at all.
// 3. The view parser reads the SELECT list ITSELF, and it can follow neither a
//    `--` comment nor an expression spanning newlines: both come back as
//    "invalid identifier parts". So every computed column below sits on one
//    line, however long, and every explanation sits out here.
//
// ── What is NOT in the view, and why (eiermann-upa.16) ─────────────────────
//
// The projection below leaves out exactly three of `spots`' fields:
// `pause_reason`, `closed_at` and `note`. That is a decision, not an omission,
// and it is written here because this is where the next person is tempted: a
// screen wants one more number, and the cheapest-looking move is another
// column.
//
// The rule the projection follows is **a column earns its place by being
// something a row or a PIN DRAWS.** Which is why the neighbours of those three
// are here and they are not:
//
//   * `closed_reason` IS carried — six months on it answers the only question
//     anybody asks of a closed Spot, and netted and refused are opposite
//     answers. `closed_at` is not: the date changes nothing a reader does.
//   * `paused_until` IS carried — the list says how long the pause is expected
//     to last. `pause_reason` is free text; a row can only truncate it.
//   * `access_note` IS carried, and it is the strongest case for the rule
//     rather than against it: it is the single most valuable field in a
//     handover, so it earns its width. `note` earns nothing — it is whatever
//     somebody needed to write down.
//
// Adding the three back makes every list row wider without making it say more,
// and the reader who needs them is already in the dossier: it reads the whole
// record through `SpotsRepository.getOne`, not through this view. The Dart side
// states the same thing from the consumer's end, on the `spot` provider.
//
// A widened version of this view would be a NEW migration: a view definition is
// schema, and schema changes forward. Phase 03 was expected to write one and did
// not — it gave the nests their own view (`nest_state`) instead, which left this
// projection untouched. So the paragraph above is addressed to whoever writes
// that migration after all: the dashboard (eiermann-jbk.11) and the statistics
// (Phase 07). The per-Spot counts they need ARE numbers a row draws, which is
// exactly why they belong here and the three fields above do not.

const MEMBER = '@request.auth.id != "" && @request.auth.is_active = true' +
  ' && @request.auth.role != null';

migrate(
  (app) => {
    const overview = new Collection({
      type: "view",
      name: "spot_overview",
      // Same scope as the underlying rows. A view does NOT inherit its source's
      // rules — forgetting this is how a carefully scoped table becomes readable
      // through a view over it.
      listRule: `${MEMBER} && org = @request.auth.org`,
      viewRule: `${MEMBER} && org = @request.auth.org`,
      // ── The urgency rank, explained here because the SQL cannot be ──────
      // PocketBase's view parser does NOT tolerate `--` comments inside
      // viewQuery: it folds them into the following expression and rejects the
      // whole thing as an invalid identifier. So the reasoning lives out here.
      //
      // The ladder, lowest number first, because the map sorts and colours by
      // it and a list wants the loudest thing on top:
      //
      //   0  overdue        — a due date in the past
      //   1  due today
      //   2  due within a week
      //   3  active, not due yet
      //   4  a prospect     — needs a conversation, not a visit
      //   5  paused
      //   6  closed
      //
      // A Spot with an active phase and NO due date ranks 3, not 0. It is
      // waiting for its first nest, not overdue — reading a missing date as
      // urgent would paint every new building red on the day it is added, and
      // a colour that is always red is a colour people stop reading.
      viewQuery: `
        SELECT
          s.id AS id,
          s.org AS org,
          s.name AS name,
          s.street AS street,
          s.postal_code AS postal_code,
          s.city AS city,
          s.geo AS geo,
          s.geo_confirmed AS geo_confirmed,
          s.phase AS phase,
          s.prospect_stage AS prospect_stage,
          s.paused_until AS paused_until,
          s.closed_reason AS closed_reason,
          s.access_note AS access_note,
          s.facade_photo AS facade_photo,
          s.next_due_at AS next_due_at,
          s.created AS created,
          s.updated AS updated,
          (SELECT COUNT(*) FROM spot_contacts c WHERE c.spot = s.id) AS contact_count,
          (SELECT COUNT(*) FROM spot_contacts c WHERE c.spot = s.id AND c.is_primary = TRUE) AS primary_contact_count,
          (CASE WHEN s.phase = 'closed' THEN 6 WHEN s.phase = 'paused' THEN 5 WHEN s.phase = 'prospect' THEN 4 WHEN s.next_due_at IS NULL OR s.next_due_at = '' THEN 3 WHEN DATE(s.next_due_at) < DATE('now') THEN 0 WHEN DATE(s.next_due_at) = DATE('now') THEN 1 WHEN DATE(s.next_due_at) <= DATE('now', '+7 days') THEN 2 ELSE 3 END) AS urgency
        FROM spots s
      `,
    });
    app.save(overview);
  },
  (app) => {
    app.delete(app.findCollectionByNameOrId("spot_overview"));
  },
);
