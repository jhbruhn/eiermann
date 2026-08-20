/// <reference path="../pb_data/types.d.ts" />

// federfall-185w / -0tf / -2asj / -509 — the geocode proxy's two handlers and
// its cache purge.
//
// Usage — the app owns the ROUTES, because their paths carry its service name,
// and the rate-limit budget for them belongs in its zv_rate_limits config:
//
//   const cfg = () => ({ envPrefix: "EIERMANN", walledOffRole: "guest" });
//   routerAdd("GET", "/api/eiermann/geocode", (e) =>
//     require(`${__hooks}/zv_geocode_route.js`).forward(e, cfg()),
//     $apis.requireAuth(),
//   );
//   routerAdd("GET", "/api/eiermann/geocode/reverse", (e) =>
//     require(`${__hooks}/zv_geocode_route.js`).reverse(e, cfg()),
//     $apis.requireAuth(),
//   );
//   cronAdd("geocodeCachePurge", "0 4 * * *", () =>
//     require(`${__hooks}/zv_geocode_route.js`).purgeCache(),
//   );
//
// PocketBase runs each route handler in an isolated JSVM context, so it cannot
// see file-level helpers — but a `require()`d module IS shared across those
// contexts, which is how the cache, the result normalisation and the upstream
// config live in ONE place (zv_geocode.js) instead of once per handler.
//
// The rate limit itself is applied by zv_rate_limits.js, with every other budget
// the app sets: PocketBase's limiter is configured through
// `settings.rateLimits`, one stored list, and a second hook rewriting that list
// is how a rule gets silently dropped (federfall-sjtg).

/** Refuses a role that is walled off from all data elsewhere. */
function refuseWalledOff(e, config) {
  // Without this check a walled-off account could still drive the server-side
  // geocoder and burn the upstream Nominatim budget (federfall-2asj) — the one
  // thing the access rules cannot stop, because there is no record to scope.
  const walledOff = String((config && config.walledOffRole) || "");
  if (walledOff && e.auth && e.auth.getString("role") === walledOff) {
    throw new ForbiddenError("Not allowed.");
  }
}

/** Forward geocode: address → candidates. */
function forward(e, config) {
  refuseWalledOff(e, config);
  const geo = require(`${__hooks}/zv_geocode.js`).withEnv(config.envPrefix);
  const up = geo.upstream();

  const q = e.request.url.query().get("q");
  if (!q) return e.json(400, { error: "missing q" });
  // No legitimate address needs more — an unbounded q would be relayed verbatim
  // to the upstream geocoder (federfall-0tf).
  if (q.length > 256) return e.json(400, { error: "q too long" });
  // Normalisation: lowercase + collapse whitespace so "Berlin" / "  berlin "
  // share one entry.
  const cacheKey = q.trim().toLowerCase().replace(/\s+/g, " ");
  if (!cacheKey) return e.json(400, { error: "missing q" });

  const cached = geo.cacheGet(e.app, "forward", cacheKey);
  if (cached !== null) return e.json(200, cached);

  // $http.send THROWS on a connection-level failure (refused, DNS, timeout)
  // rather than returning a status, and an uncaught throw here is rendered as a
  // generic 400 — telling the client its request was bad when the request was
  // fine and the geocoder was unreachable. That is the likeliest failure of all,
  // since the upstream URL is operator-set. Same 502 as an upstream error
  // status, and likewise never cached.
  let res;
  try {
    res = $http.send({
      url:
        up.base +
        "/search?format=jsonv2&addressdetails=1&limit=5&q=" +
        encodeURIComponent(q) +
        (up.key ? "&api_key=" + encodeURIComponent(up.key) : ""),
      method: "GET",
      headers: { "User-Agent": up.ua },
      timeout: 10,
    });
  } catch (err) {
    $app
      .logger()
      .warn("geocoder forward unreachable", "err", String(err), "base", up.base);
    return e.json(502, { error: "geocoder unavailable" });
  }
  if (res.statusCode !== 200) {
    $app
      .logger()
      .warn("geocoder forward failed", "status", res.statusCode, "base", up.base);
    // Do not cache upstream failures — a transient outage must not be stored as
    // "not found".
    return e.json(502, { error: "geocoder unavailable" });
  }

  const results = (res.json || []).map(geo.toResult);
  const payload = { results: results };
  geo.cachePut(e.app, "forward", cacheKey, payload, results.length);
  return e.json(200, payload);
}

/** A coordinate must be a plain number, not merely something parseFloat can
 * salvage: `52.5abc` passed parseFloat + isFinite and was then relayed upstream
 * verbatim (federfall-185w). Exponent form is accepted because Dart's
 * `double.toString()` can emit it. */
const NUMERIC = /^[+-]?\d+(\.\d+)?([eE][+-]?\d+)?$/;

/** Reverse geocode: pin → address. */
function reverse(e, config) {
  refuseWalledOff(e, config);
  const geo = require(`${__hooks}/zv_geocode.js`).withEnv(config.envPrefix);
  const up = geo.upstream();

  const query = e.request.url.query();
  const lat = query.get("lat");
  const lon = query.get("lon");
  if (!lat || !lon) return e.json(400, { error: "missing lat/lon" });
  if (!NUMERIC.test(lat.trim()) || !NUMERIC.test(lon.trim())) {
    return e.json(400, { error: "invalid lat/lon" });
  }
  const latN = parseFloat(lat);
  const lonN = parseFloat(lon);
  if (
    !isFinite(latN) ||
    !isFinite(lonN) ||
    latN < -90 ||
    latN > 90 ||
    lonN < -180 ||
    lonN > 180
  ) {
    return e.json(400, { error: "invalid lat/lon" });
  }
  // Normalisation: round to ~1m so near-identical pins share one entry.
  //
  // ONE rounded pair feeds both the cache key and the upstream query, so an
  // entry cannot describe a different point from the one that was asked about.
  // federfall validated the PARSED coordinate and forwarded the RAW string,
  // which meant `lat=52.5abc` survived parseFloat + isFinite, was keyed as
  // "52.50000", and was then relayed verbatim — two different upstream queries
  // sharing one entry, whichever landed first winning it.
  const latQ = latN.toFixed(5);
  const lonQ = lonN.toFixed(5);
  const cacheKey = latQ + "," + lonQ;

  const cached = geo.cacheGet(e.app, "reverse", cacheKey);
  if (cached !== null) return e.json(200, cached);

  // As on the forward route: a connection-level failure throws, and an uncaught
  // throw would report a fine request as a 400.
  let res;
  try {
    res = $http.send({
      url:
        up.base +
        "/reverse?format=jsonv2&addressdetails=1&lat=" +
        encodeURIComponent(latQ) +
        "&lon=" +
        encodeURIComponent(lonQ) +
        (up.key ? "&api_key=" + encodeURIComponent(up.key) : ""),
      method: "GET",
      headers: { "User-Agent": up.ua },
      timeout: 10,
    });
  } catch (err) {
    $app
      .logger()
      .warn("geocoder reverse unreachable", "err", String(err), "base", up.base);
    return e.json(502, { error: "geocoder unavailable" });
  }
  if (res.statusCode !== 200) {
    $app
      .logger()
      .warn("geocoder reverse failed", "status", res.statusCode, "base", up.base);
    return e.json(502, { error: "geocoder unavailable" });
  }

  // Nominatim returns 200 with {error: "Unable to geocode"} when nothing is
  // found — treat that as a (cacheable) negative result, not an address.
  const raw = res.json || {};
  const found = !raw.error && raw.lat != null;
  const payload = { result: found ? geo.toResult(raw) : null };
  geo.cachePut(e.app, "reverse", cacheKey, payload, found ? 1 : 0);
  return e.json(200, payload);
}

/**
 * federfall-509 — purge expired cache rows. Keeps the table bounded and
 * guarantees stale entries eventually disappear even if they are never
 * re-queried (a re-query refreshes in place; this is for the long tail that is
 * not).
 */
function purgeCache() {
  const PAGE = 500;
  const now = new Date().toISOString().replace("T", " ");
  let purged = 0;
  let offset = 0;
  // Re-query from the same offset each round: deleting shrinks the result set,
  // so the next page of still-expired rows slides back to the front.
  //
  // federfall-ex20 — but only rows that ACTUALLY went away slide. A row whose
  // delete keeps failing (locked, or held by a constraint) stays in the filter
  // at the same position, and with a fixed offset of 0 a full page of those
  // refills the batch forever: `batch.length < PAGE` never becomes true and the
  // cron spins until the process is killed. Advancing past a page that removed
  // nothing steps over the stuck rows instead.
  for (;;) {
    let batch;
    try {
      batch = $app.findRecordsByFilter(
        "geocode_cache",
        "expires_at < {:now}",
        "expires_at",
        PAGE,
        offset,
        { now: now },
      );
    } catch (_) {
      break;
    }
    if (!batch || batch.length === 0) break;
    let purgedThisBatch = 0;
    for (let i = 0; i < batch.length; i++) {
      try {
        $app.delete(batch[i]);
        purged++;
        purgedThisBatch++;
      } catch (_) {
        // Skip a row already gone / locked; the next run retries it.
      }
    }
    if (purgedThisBatch === 0) offset += batch.length;
    if (batch.length < PAGE) break;
  }
  if (purged > 0) {
    $app.logger().info("geocode cache purge", "removed", purged);
  }
}

module.exports = {
  forward: forward,
  reverse: reverse,
  purgeCache: purgeCache,
  NUMERIC: NUMERIC,
};
