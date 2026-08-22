/// <reference path="../pb_data/types.d.ts" />

// eiermann — from zugvogel's template. The library holds the reasoning.
//
// The ONE writer of settings.rateLimits. zv_rate_limits.js holds the merge, the
// factory-default restore and — importantly — why every label must be
// METHOD-QUALIFIED: a bare prefix loses to PocketBase's own `/api/` rule and
// budgets nothing at all, silently.
//
// WHICH routes need a budget is the app's: the ones that spawn a subprocess or
// relay to a rate-limited third party.

onBootstrap((e) => {
  e.next();
  require(`${__hooks}/zv_rate_limits.js`).apply(e, {
    envPrefix: "EIERMANN",
    groups: [
      {
        name: "geocode",
        labels: [
          "GET /api/eiermann/geocode",
          "GET /api/eiermann/geocode/",
        ],
        maxEnv: "GEOCODE_RATE_MAX",
        windowEnv: "GEOCODE_RATE_WINDOW",
        maxDefault: 30,
        windowDefault: 60,
      },
      // eiermann-fi2.6 — the report route spawns a `typst compile` per request
      // and reads every visit of the period to feed it. One process per request
      // is what makes a loop expensive for the SERVER rather than for the
      // caller, which is the whole reason this group exists.
      //
      // Both PDF formats and the CSV share one budget because they share one
      // route; a trailing-slash twin is listed for the same reason the geocode
      // group has one. Ten a minute is far above any human use — a coordinator
      // pulling a year, a month and last year's comparison is three — and far
      // below what a loop needs to hurt.
      {
        name: "reports",
        labels: [
          "GET /api/eiermann/reports/period",
          "GET /api/eiermann/reports/period/",
        ],
        maxEnv: "REPORT_RATE_MAX",
        windowEnv: "REPORT_RATE_WINDOW",
        maxDefault: 10,
        windowDefault: 60,
      },
    ],
  });
});
