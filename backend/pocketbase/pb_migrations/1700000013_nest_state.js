/// <reference path="../pb_data/types.d.ts" />

// eiermann-bmg.6 — nest_state: the nest list in the Spot dossier reads ONE query.
//
// The concept is explicit about what must stand on the dossier without
// scrolling: the overview photo with its pins, and under it one line per nest
// with its CONTENT and its AGE, urgent first. The content is the Ist-Gelege —
// how many real eggs and how many dummies are in that nest right now — and it
// lives in `nest_eggs`, one row per egg. Reading that per nest is one request
// per row, which is the thing that makes an app feel broken on a phone in a
// stairwell. Hence a view.
//
// ── What is NOT computed here, and why ─────────────────────────────────────
//
// No "days in state" column, although the list shows exactly that. The dates go
// out raw (`oldest_since`, `last_checked_at`) and the client subtracts them,
// because PocketBase stores UTC and SQLite's DATE('now') is UTC too: a
// difference computed here would be right in Greenwich and off by a day in CET
// for everything recorded after 22:00 local. The client already routes every
// date through `formatLocalDate` for the same reason.
//
// A computed column also comes back typed `json`, so a number crossing this
// boundary arrives quoted unless it is a plain integer expression. The counts
// and the rank below are; a date arithmetic result would not be.
//
// ── The urgency ladder ─────────────────────────────────────────────────────
//
// Same shape as `spot_overview`'s, lowest number loudest, because the list sorts
// by it:
//
//   0  overdue          — a due date in the past
//   1  due today
//   2  due within a week
//   3  active, not due yet (including a nest with no due date at all)
//   4  protected        — cannot be worked, so it cannot be urgent
//   5  gone             — recorded history, not work
//
// `protected` outranking the due dates is deliberate. Every egg mutation on such
// a nest is refused server-side, so a due date on it describes nothing anybody
// may act on. It keeps a rank of its OWN rather than being filtered out: a
// jackdaw in the attic is exactly what the next person needs to see before they
// go up there.
//
// A nest with an active status and no due date ranks 3, not 0 — it has never
// been checked, which is not the same as overdue, and painting every fresh nest
// red on the day it is drawn is how a colour stops being read.

const MEMBER = '@request.auth.id != "" && @request.auth.is_active = true' +
  ' && @request.auth.role != null';

migrate(
  (app) => {
    const state = new Collection({
      type: "view",
      name: "nest_state",
      // A view does NOT inherit the rules of the tables under it. Stating the
      // same scope as `nests` here is what keeps this from being a public
      // window onto them.
      listRule: `${MEMBER} && org = @request.auth.org`,
      viewRule: `${MEMBER} && org = @request.auth.org`,
      // Every computed column is ONE line, however long: the view parser reads
      // the SELECT list itself and follows neither a `--` comment nor an
      // expression spanning newlines — both come back as "invalid identifier
      // parts". The reasoning is in the header above.
      viewQuery: `
        SELECT
          n.id AS id,
          n.org AS org,
          n.spot AS spot,
          n.area AS area,
          n.label AS label,
          n.position_hint AS position_hint,
          n.pin_x AS pin_x,
          n.pin_y AS pin_y,
          n.photo AS photo,
          n.species AS species,
          n.species_label AS species_label,
          n.status AS status,
          n.interval_days AS interval_days,
          n.empty_streak AS empty_streak,
          n.next_due_at AS next_due_at,
          n.note AS note,
          n.created AS created,
          n.updated AS updated,
          (SELECT COUNT(*) FROM nest_eggs e WHERE e.nest = n.id AND e.kind = 'real') AS real_count,
          (SELECT COUNT(*) FROM nest_eggs e WHERE e.nest = n.id AND e.kind = 'dummy') AS dummy_count,
          (SELECT MIN(e.since) FROM nest_eggs e WHERE e.nest = n.id) AS oldest_since,
          (SELECT MAX(c.checked_at) FROM nest_checks c WHERE c.nest = n.id) AS last_checked_at,
          (CASE WHEN n.status = 'gone' THEN 5 WHEN n.species = 'protected' THEN 4 WHEN n.next_due_at IS NULL OR n.next_due_at = '' THEN 3 WHEN DATE(n.next_due_at) < DATE('now') THEN 0 WHEN DATE(n.next_due_at) = DATE('now') THEN 1 WHEN DATE(n.next_due_at) <= DATE('now', '+7 days') THEN 2 ELSE 3 END) AS urgency
        FROM nests n
      `,
    });
    app.save(state);
  },
  (app) => {
    app.delete(app.findCollectionByNameOrId("nest_state"));
  },
);
