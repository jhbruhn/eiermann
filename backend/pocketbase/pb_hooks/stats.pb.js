/// <reference path="../pb_data/types.d.ts" />

// eiermann-fi2.3 — GET /api/eiermann/stats: everything the statistics screen
// shows, computed server-side over the `visit_rows` view.
//
// ── Why the server aggregates and the client does not ──────────────────────
//
// The alternative is the client pulling `visits` + `nest_checks` + `findings`
// unpaginated to the device and summing them. It is wrong twice over: it is the
// `?page=` mistake at a larger scale (a monthly series with last year behind it
// needs MORE history than a screen, not less), and it puts a second definition
// of "Eier entnommen" in the app — one that will disagree with the printed
// report the first time either side is touched.
//
// So every figure comes from app_stats.js, which report.pb.js also uses: "2026"
// is one instant range, a rate has one denominator, and the screen and the PDF
// cannot contradict each other. The client aggregates NOTHING.
//
// ── Response ───────────────────────────────────────────────────────────────
// {
//   "period": { "year": 2026 | null, "month": 3 | null },
//   "totals": { "visits", "visitsChecked", "visitsSkipped", "spotsVisited",
//               "checks", "removedReal", "addedDummy", "findings",
//               "accessRate"|null, "fullSwapRate"|null,
//               "eggsPerCheckedVisit"|null },
//   "series": { "kind": "day" | "month" | "year",
//               "points":   [{ "key", "visits", "removed", "dummies" }],
//               "previous": { "year", "month", "points": [...] } | null },
//   "checkStates":    [{ "state": "swapped", "count": n }],
//   "findingKinds":   [{ "kind": "dead_bird", "count": n }],
//   "findingSpecies": [{ "label": "Dohle", "count": n }],
//   "skipReasons":    [{ "reason": "no_key", "count": n }],
//   "addresses":      [{ "label": "Musterstraße 5, 26121 Oldenburg", "count": n }],
//   "visitYears":     [2026, 2025],
//   "spots": { "total", "phases": [{ "phase", "count" }],
//              "prospectStages": [{ "stage", "count" }] }
// }
//
// `series.kind` follows the period: "day" for a selected month (keys 1..28-31),
// "month" for a selected year (keys 1–12), "year" over all time (keys are
// calendar years, the span filled in so a quiet year is a zero column and not a
// missing one). Every bucket is emitted even at zero.
//
// `previous` is the SAME period one year earlier — last March for March, never
// February. Seasonality is the question this screen is asked ("are we busier
// than last spring?"); the month before answers a different one and answers it
// badly, because half the difference is just the season turning. It is omitted
// when that period held no visits at all, since an all-zero comparison is noise
// rather than a comparison.
//
// `spots` is the one block here that is NOT period-scoped: it is what the org
// has access to right now, which `?year=` has no bearing on. The screen must
// present it as a standing figure and never inside a period's card.
//
// Values stay WIRE strings — `swapped`, `no_key`, `dead_bird`. A hook never
// sends user-facing text: the server does not know which language the reader
// speaks, so a German string here would be untranslatable by construction. The
// client maps them, exactly as it maps a refusal code.
routerAdd(
  "GET",
  "/api/eiermann/stats",
  (e) => {
    // Required INSIDE the handler, absolute `${__hooks}` form: every handler
    // runs in its own JSVM context, and a file-level binding is a
    // ReferenceError at request time that surfaces as a generic 400.
    const stats = require(`${__hooks}/app_stats.js`);

    // The gate, from the one place that states it (app_auth.js): an active
    // caller whose role is NAMED. `role != null` is satisfied by `guest`, and a
    // route that checks only for one hands every stranger the identity provider
    // authenticated a complete export of the organisation's addresses.
    const { org } = require(`${__hooks}/app_auth.js`).requireMember(e);

    const query = e.request.url.query();
    const period = stats.parsePeriod(query);
    const year = period.year;
    const month = period.month;
    const t = require(`${__hooks}/zv_time.js`).timeContext(query);

    // Every visit on record, ONCE, then partitioned in JS. The selected period,
    // the previous year's series and the list of years with visits all come out
    // of this one read, where three filtered queries would cost three passes
    // over the same view.
    //
    // Bucketing by the row's LOCAL visit year is equivalent to the report's
    // `visited_at >= from && < to` filter: both resolve the boundary through
    // the caller's own offset, so a visit at 00:30 on New Year's Day lands in
    // the same year in the chart and in the PDF. app_stats_test.js asserts that
    // equivalence directly; the rule suite asserts it end to end.
    const rows = stats.loadVisitRows(e.app, org, null, t);
    const partsOf = (row) => t.partsOf(row.visitedAt);
    const rowsIn = (y, mo) =>
      rows.filter((r) => {
        const p = partsOf(r);
        return p !== null && p.y === y && (mo === null || p.mo === mo);
      });

    const periodRows = year === null ? rows : rowsIn(year, month);
    const agg = stats.aggregate(periodRows, { t: t, period: period });

    let previous = null;
    if (year !== null) {
      const prevPeriod = { year: year - 1, month: month };
      const prevRows = rowsIn(prevPeriod.year, month);
      if (prevRows.length > 0) {
        previous = {
          year: prevPeriod.year,
          month: month,
          points: stats.aggregate(prevRows, { t: t, period: prevPeriod }).points,
        };
      }
    }

    // Org-wide regardless of the selected period: this is what the period
    // picker offers, and offering only the selected year would be a picker that
    // cannot leave it.
    const seen = {};
    const visitYears = [];
    for (const r of rows) {
      const p = partsOf(r);
      if (p === null || seen[p.y]) continue;
      seen[p.y] = true;
      visitYears.push(p.y);
    }
    visitYears.sort((a, b) => b - a);

    const standing = stats.spotStanding(e.app, org);
    return e.json(200, {
      period: { year: year, month: month },
      totals: agg.totals,
      series: {
        kind: agg.bucketKind,
        points: agg.points,
        previous: previous,
      },
      // `{label, count}` from the module → a key that names what the value IS.
      // These are wire values, not display labels, and the reader translates
      // them; naming the field `state` rather than `label` is what stops a
      // client printing one straight into the UI.
      checkStates: agg.checkStates.map((s) => ({
        state: s.label,
        count: s.count,
      })),
      findingKinds: agg.findingKinds.map((f) => ({
        kind: f.label,
        count: f.count,
      })),
      // Free text a volunteer typed, so `label` is right here: there is nothing
      // to translate and nothing to map.
      findingSpecies: stats.findingSpecies(e.app, org, periodRows),
      skipReasons: agg.skipReasons.map((s) => ({
        reason: s.label,
        count: s.count,
      })),
      addresses: agg.addresses,
      visitYears: visitYears,
      spots: {
        total: standing.total,
        phases: standing.phases.map((p) => ({ phase: p.label, count: p.count })),
        prospectStages: standing.prospectStages.map((p) => ({
          stage: p.label,
          count: p.count,
        })),
      },
    });
  },
  $apis.requireAuth(),
);
