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
      // Add a group per route that shells out to a subprocess — a Typst
      // compile, say. One process per request is what makes a loop expensive
      // for the server rather than for the caller.
    ],
  });
});
