/// <reference path="../pb_data/types.d.ts" />

// eiermann — from zugvogel's template. The library holds the reasoning.
//
// The geocode proxy. zv_geocode_route.js holds both handlers, the cache purge
// and the reasons: why a coordinate must be a plain number, why one rounded pair
// feeds both the cache key and the upstream query, and why an unreachable
// upstream is a 502 rather than the 400 an uncaught throw would produce.
//
// The rate limit for these routes is applied by rate_limits.pb.js, not here.

const config = () => ({
  envPrefix: "EIERMANN",
  // A role that is walled off from all data elsewhere could still drive the
  // geocoder and burn the upstream budget — the one thing an access rule cannot
  // stop, because there is no record to scope.
  walledOffRole: "guest",
});

routerAdd(
  "GET",
  "/api/eiermann/geocode",
  (e) => require(`${__hooks}/zv_geocode_route.js`).forward(e, config()),
  $apis.requireAuth(),
);

routerAdd(
  "GET",
  "/api/eiermann/geocode/reverse",
  (e) => require(`${__hooks}/zv_geocode_route.js`).reverse(e, config()),
  $apis.requireAuth(),
);

cronAdd("geocodeCachePurge", "0 4 * * *", () =>
  require(`${__hooks}/zv_geocode_route.js`).purgeCache(),
);
