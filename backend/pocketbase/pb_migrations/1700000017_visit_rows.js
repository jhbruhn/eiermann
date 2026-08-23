/// <reference path="../pb_data/types.d.ts" />

// eiermann-fi2.1 — visit_rows: the report table, defined once.
//
// Three consumers read this view and not one of them selects a column of its
// own: the authority PDF per address, the funder summary, and the CSV export.
// That is the whole reason it exists. The three used to be one report; the
// moment they are three code paths over `visits` + `nest_checks` + `findings`,
// "Eier entnommen" starts meaning `SUM(removed_real)` in one of them and
// `SUM(real_before) - SUM(real_after)` in another — both defensible, both
// printed under the same heading, and nobody notices until a Behörde adds up
// two documents from the same export.
//
// ── The grain is ONE VISIT ─────────────────────────────────────────────────
//
// A row is a trip to a building, because that is the line a report prints:
// "Musterstraße 5, 14.03.2026, 4 Eier entnommen, 4 Attrappen gelegt". The
// per-nest detail is deliberately NOT the grain — a Behörde asks what was done
// at an address on a date, and a nest-grained table answers a question about
// nests while making the address question a sum the reader has to do.
//
// The nest numbers therefore arrive as scalar subqueries over `nest_checks`.
// This is what the concept's "checks are stored as scalars, so every report is
// plain SQL" buys: no JSON, no aggregation in a hook, no client arithmetic.
//
// ── A skipped visit keeps its row ──────────────────────────────────────────
//
// `outcome = skipped` is a document, not an observation (see 1700000009), and
// its row stays in the table with zeros in the egg columns and its
// `skip_reason` intact. Filtering it out would make the report claim the
// building was never visited that month, which is the opposite of what the
// volunteer recorded — and the count of failed attempts at an address is
// exactly what an application for a key is argued with.
//
// ── Why the check breakdown is here and not derived later ──────────────────
//
// One column per `nest_checks.state`, plus `checks_total`. The census is
// COMPLETE on purpose — all seven states, so the columns sum to `checks_total`
// and a reader can reconcile the line without being told which states were
// folded into an "other". A partial census is the version of this table that
// makes a Behörde ask what the missing checks were.
//
// Deriving them in `app_stats.js` from a nest-grained read would be a second
// query over the same rows, and the summary and the PDF would then have two
// chances to disagree about whether `not_reachable` counts as "geprüft".
//
// `protected_count` earns its column twice over: it is the printed proof that
// nothing was touched where a protected species was sitting, which is the one
// number in this table that answers a legal question rather than a workload
// one.
//
// ── findings_text ─────────────────────────────────────────────────────────
//
// One cell, `kind` values joined with "; " — the wire values, not German. A
// view has no reader's language, and the same rule holds here as everywhere
// else in this backend: the server ships wire values and the client (or the
// Typst template, or shared_strings.json for the CSV) maps them. `GROUP_CONCAT`
// with an explicit separator, because SQLite's default is a bare comma and this
// cell then breaks a CSV column that quoting alone would have saved — the
// consumers split on "; " to count a breakdown.
//
// Species labels are NOT folded in: they are free text a volunteer typed, and
// "Dohle; Turmfalke" inside a cell that a consumer splits on "; " is a value
// that mis-splits itself. A report that needs the labels reads `findings`.

// The role clause is an ALLOWLIST, not `role != null`. Migration 014 rewrote
// every rule in the database for exactly this reason: `guest` — where a
// self-registered OAuth2 account lands — IS a non-null role, so the old clause
// would make this view a window onto every visit the org has ever recorded, for
// any stranger the identity provider happened to authenticate. 014 can only
// rewrite the rules that existed when it ran; a view written afterwards has to
// get it right itself.
const MEMBER = '@request.auth.id != "" && @request.auth.is_active = true' +
  ' && (@request.auth.role = "member" || @request.auth.role = "coordinator")';

migrate(
  (app) => {
    const rows = new Collection({
      type: "view",
      name: "visit_rows",
      // A view does NOT inherit the rules of the tables under it. Without these
      // two lines this is a public window onto every visit every organisation
      // has ever recorded.
      //
      // Same scope as `visits` itself: every active member of the org reads it.
      // Reporting is not a coordinator privilege here — federfall gates its
      // reports on a third role level, and this app deliberately has two (the
      // concept: "everybody does field work and sees everything").
      listRule: `${MEMBER} && org = @request.auth.org`,
      viewRule: `${MEMBER} && org = @request.auth.org`,
      // Every computed column is ONE line, however long. PocketBase parses this
      // SELECT list itself and follows neither a `--` comment nor an expression
      // wrapped across newlines: both come back as "invalid identifier parts".
      // The reasoning lives in the header above.
      //
      // The COUNT/SUM columns are bare integer expressions so they cross the
      // wire as numbers. A computed column falls back to type `json`, and a
      // server-side reader gets the raw JSON — which is why app_stats.js asks
      // the collection for each field's type and decodes rather than guessing.
      // `COALESCE(SUM(...), 0)`: SQLite's SUM over no rows is NULL, and a
      // skipped visit has no checks, so without it the egg columns of every
      // skipped row would read as "unknown" instead of "none".
      viewQuery: `
        SELECT
          v.id AS id,
          v.org AS org,
          v.spot AS spot,
          s.name AS spot_name,
          s.street AS street,
          s.postal_code AS postal_code,
          s.city AS city,
          v.visited_at AS visited_at,
          v.outcome AS outcome,
          v.skip_reason AS skip_reason,
          v.note AS note,
          v.author_name AS author_name,
          v.created AS created,
          (SELECT COUNT(*) FROM nest_checks c WHERE c.visit = v.id) AS checks_total,
          (SELECT COUNT(*) FROM nest_checks c WHERE c.visit = v.id AND c.state = 'swapped') AS swapped_count,
          (SELECT COUNT(*) FROM nest_checks c WHERE c.visit = v.id AND c.state = 'partial') AS partial_count,
          (SELECT COUNT(*) FROM nest_checks c WHERE c.visit = v.id AND c.state = 'empty') AS empty_count,
          (SELECT COUNT(*) FROM nest_checks c WHERE c.visit = v.id AND c.state = 'untouched') AS untouched_count,
          (SELECT COUNT(*) FROM nest_checks c WHERE c.visit = v.id AND c.state = 'not_reachable') AS not_reachable_count,
          (SELECT COUNT(*) FROM nest_checks c WHERE c.visit = v.id AND c.state = 'gone') AS gone_count,
          (SELECT COUNT(*) FROM nest_checks c WHERE c.visit = v.id AND c.state = 'protected') AS protected_count,
          (SELECT COALESCE(SUM(c.removed_real), 0) FROM nest_checks c WHERE c.visit = v.id) AS removed_real,
          (SELECT COALESCE(SUM(c.added_dummy), 0) FROM nest_checks c WHERE c.visit = v.id) AS added_dummy,
          (SELECT COUNT(*) FROM findings f WHERE f.visit = v.id) AS findings_total,
          (SELECT GROUP_CONCAT(f.kind, '; ') FROM findings f WHERE f.visit = v.id) AS findings_text
        FROM visits v
        LEFT JOIN spots s ON s.id = v.spot
      `,
    });
    app.save(rows);
  },
  (app) => {
    app.delete(app.findCollectionByNameOrId("visit_rows"));
  },
);
