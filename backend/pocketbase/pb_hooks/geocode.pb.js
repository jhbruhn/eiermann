/// <reference path="../pb_data/types.d.ts" />

// eiermann — from zugvogel's template. The library holds the reasoning.
//
// The geocode proxy. zv_geocode_route.js holds both handlers, the cache purge
// and the reasons: why a coordinate must be a plain number, why one rounded pair
// feeds both the cache key and the upstream query, and why an unreachable
// upstream is a 502 rather than the 400 an uncaught throw would produce.
//
// The rate limit for these routes is applied by rate_limits.pb.js, not here.
//
// The config is built INSIDE each handler and not once at file level. Every
// handler runs in its own JSVM context, so a file-level `const config = …` is
// simply not in scope when the handler runs: the call throws
// `ReferenceError: config is not defined` at REQUEST time, and PocketBase
// reports it as a generic 400. That is what this file did until it was actually
// called — a shape that survives review, boots without complaint, and fails
// only in production. Repeating the literal in three handlers is the price of
// the runtime it runs in.

routerAdd(
  "GET",
  "/api/eiermann/geocode",
  (e) =>
    require(`${__hooks}/zv_geocode_route.js`).forward(e, {
      envPrefix: "EIERMANN",
      // A role that is walled off from all data elsewhere could still drive
      // the geocoder and burn the upstream budget — the one thing an access
      // rule cannot stop, because there is no record to scope.
      walledOffRole: "guest",
    }),
  $apis.requireAuth(),
);

routerAdd(
  "GET",
  "/api/eiermann/geocode/reverse",
  (e) =>
    require(`${__hooks}/zv_geocode_route.js`).reverse(e, {
      envPrefix: "EIERMANN",
      walledOffRole: "guest",
    }),
  $apis.requireAuth(),
);

cronAdd("geocodeCachePurge", "0 4 * * *", () =>
  require(`${__hooks}/zv_geocode_route.js`).purgeCache(),
);
