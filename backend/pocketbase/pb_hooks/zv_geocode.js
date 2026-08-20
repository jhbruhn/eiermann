/// <reference path="../pb_data/types.d.ts" />

// federfall-185w — the geocode proxy's upstream config, result normalisation
// and cache, in ONE place.
//
// Usage — `require()` INSIDE the handler, never at file level, and always with
// the `${__hooks}` absolute form (see zv_audit.js):
//
//   const geo = require(`${__hooks}/zv_geocode.js`).withEnv("EIERMANN");
//   const up = geo.upstream();
//   const cached = geo.cacheGet(e.app, "reverse", cacheKey);
//
// ── Why this is a module and not two copies ─────────────────────────────────
// federfall's geocode route had `toResult`, `cacheGet`, `cachePut`, the TTL
// constants and the env reads written out twice — byte-identical between the
// forward and reverse handlers apart from the `"forward"` / `"reverse"` kind
// string. Two copies of a cache is two places for a TTL, a key normalisation or
// an expiry comparison to drift — in the one hook that talks to a rate-limited
// third party, where a drift is paid for in somebody else's quota.
//
// ── The env prefix is injected ──────────────────────────────────────────────
// An operator configures the geocoder per deployment, and the variables are
// named after the app: `FEDERFALL_NOMINATIM_URL`, `EIERMANN_NOMINATIM_URL`.
// Hardcoding one app's prefix here would make the other app's deployment
// silently un-configurable — it would read variables nobody set and fall
// through to the public Nominatim, which is rate-limited and whose usage policy
// an application backend does not really fit. So the prefix is a parameter.
//
// STATELESS, like every zv_ module: PocketBase pools JSVMs and each pooled VM
// holds its own instance, so nothing is cached between calls. Env is re-read per
// request, which is also what lets a test rewrite it.
//
// NOTE: `cacheGet` hands back `record.get("response")`, i.e. a `types.JSONRaw`
// byte array. That marshals correctly on its way out through `e.json(...)` but
// must never be property-accessed in JS (federfall-jumi / zv_org.js's header).
// It is returned opaquely here for exactly that reason.

const DAY_MS = 86400000;
const HOUR_MS = 3600000;

/** PocketBase stores/compares dates as "YYYY-MM-DD HH:MM:SS.sssZ". */
function pbDate(d) {
  return d.toISOString().replace("T", " ");
}

function findEntry(app, kind, key) {
  return app.findFirstRecordByFilter(
    "geocode_cache",
    "kind = {:kind} && cache_key = {:key}",
    { kind: kind, key: key },
  );
}

/**
 * One upstream hit → the normalized shape the app consumes.
 *
 * `displayName` is composed as a tidy "Street 8, 26125 City" rather than
 * Nominatim's long `display_name`, which is only used as a fallback.
 *
 * Not env-dependent, so it needs no binding.
 */
function toResult(r) {
  const a = r.address || {};
  const city = a.city || a.town || a.village || a.municipality || a.hamlet || "";
  const region = a.state || a.region || "";
  const road = a.road || a.pedestrian || a.footway || a.path || "";
  const street = road
    ? a.house_number
      ? road + " " + a.house_number
      : road
    : "";
  const locality = [a.postcode, city].filter(Boolean).join(" ");
  const composed = [street, locality].filter(Boolean).join(", ");
  return {
    lat: parseFloat(r.lat),
    lon: parseFloat(r.lon),
    displayName: composed || r.display_name || "",
    city: city,
    region: region,
  };
}

/**
 * The geocode helpers bound to an app's env-variable [prefix] (e.g.
 * `"EIERMANN"`, giving `EIERMANN_NOMINATIM_URL` and friends).
 */
function withEnv(prefix) {
  const env = (name, fallback) =>
    $os.getenv(String(prefix) + "_" + name) || fallback;

  /** Base URL, optional API key and User-Agent for the upstream geocoder. */
  function upstream() {
    return {
      base: env("NOMINATIM_URL", "https://nominatim.openstreetmap.org"),
      key: env("GEOCODER_KEY", ""),
      // The default names the app rather than a product, because Nominatim's
      // policy asks a caller to identify itself and "unknown" is worse than a
      // guess.
      ua: env("USER_AGENT", String(prefix).toLowerCase() + "/1.0"),
    };
  }

  function cacheEnabled() {
    return env("GEOCODE_CACHE_DISABLED", "") !== "1";
  }

  /**
   * The cached response for [kind]/[key], or `null` for a miss or a stale row.
   *
   * Opaque JSONRaw — hand it straight to `e.json`, never read into it.
   */
  function cacheGet(app, kind, key) {
    if (!cacheEnabled()) return null;
    let rec;
    try {
      rec = findEntry(app, kind, key);
    } catch (_) {
      return null; // miss
    }
    const exp = new Date(
      String(rec.get("expires_at")).replace(" ", "T"),
    ).getTime();
    if (isNaN(exp) || exp <= new Date().getTime()) return null; // stale → miss
    try {
      rec.set("hits", (rec.getInt("hits") || 0) + 1);
      app.save(rec);
    } catch (_) {
      // Hit accounting is best-effort; never fail a read on a write error.
    }
    return rec.get("response");
  }

  /**
   * Store [response] under [kind]/[key], refreshing an existing row in place.
   *
   * A negative result ([count] of 0) gets the much shorter TTL, so a newly
   * added address is retried soon. Upstream FAILURES are not this function's
   * business — the caller must not cache a transient outage as "not found".
   */
  function cachePut(app, kind, key, response, count) {
    if (!cacheEnabled()) return;
    const ttlDays = parseFloat(env("GEOCODE_CACHE_TTL_DAYS", "")) || 30;
    const negTtlHours = parseFloat(env("GEOCODE_CACHE_NEG_TTL_HOURS", "")) || 24;
    const ttlMs = count > 0 ? ttlDays * DAY_MS : negTtlHours * HOUR_MS;
    try {
      const col = app.findCollectionByNameOrId("geocode_cache");
      let rec;
      try {
        rec = findEntry(app, kind, key);
      } catch (_) {
        rec = new Record(col);
        rec.set("kind", kind);
        rec.set("cache_key", key);
        rec.set("hits", 0);
      }
      rec.set("response", response);
      rec.set("result_count", count);
      rec.set("expires_at", pbDate(new Date(new Date().getTime() + ttlMs)));
      app.save(rec);
    } catch (_) {
      // A concurrent miss may have inserted the same key first (unique-index
      // conflict), or any other write error — the response is unaffected.
    }
  }

  return {
    upstream: upstream,
    toResult: toResult,
    cacheGet: cacheGet,
    cachePut: cachePut,
  };
}

module.exports = {
  withEnv: withEnv,
  toResult: toResult,
};
