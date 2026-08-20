/// <reference path="../pb_data/types.d.ts" />

// eiermann-h7q.13 — the two infrastructure collections, both fully opaque.
//
// `geocode_cache` and `idempotency_keys` have NULL rules on every operation.
// That is not laziness: neither is data about the domain, neither has anything a
// client should read, and both are written exclusively by hooks. A null rule is
// the strongest statement available — superuser-only, no exceptions — and it is
// the right one for a table whose contents are an implementation detail.

migrate(
  (app) => {
    // ── geocode_cache ─────────────────────────────────────────────────────
    // In front of the Nominatim proxy. The cache exists because the upstream is
    // rate-limited and somebody else's quota is what pays for a missing cache:
    // the OSM policy allows roughly one request a second, and a round of address
    // lookups would blow through that in a burst.
    const geocodeCache = new Collection({
      type: "base",
      name: "geocode_cache",
      fields: [
        // "forward" (address → coordinates) or "reverse" (pin → address). Part
        // of the key, so the two directions cannot collide.
        { name: "kind", type: "text", required: true, max: 20 },
        // The NORMALISED query — lowercased and whitespace-collapsed for a
        // forward lookup, rounded to five decimals for a reverse one. One
        // rounded pair feeds both this key and the upstream request, so an entry
        // can never describe a different point from the one that was asked
        // about.
        { name: "cache_key", type: "text", required: true, max: 300 },
        // The upstream response, stored opaquely and handed straight back out
        // through `e.json(...)`. Never property-accessed in JS — see the
        // JSONRaw note on organisations.settings.
        { name: "response", type: "json", required: true, maxSize: 200000 },
        // 0 means "nothing found", which is cacheable but on a much shorter TTL
        // so a newly added address is retried soon.
        { name: "result_count", type: "number", required: false },
        { name: "hits", type: "number", required: false },
        { name: "expires_at", type: "text", required: true, max: 40 },
        { name: "created", type: "autodate", onCreate: true, onUpdate: false },
        { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
      ],
      indexes: [
        // UNIQUE on the pair, which is what makes a concurrent miss safe: two
        // requests for the same address race, one insert wins, the loser's
        // conflict is caught and discarded, and the response is unaffected.
        'CREATE UNIQUE INDEX idx_geocode_cache_kind_key' +
          ' ON geocode_cache (kind, cache_key)',
        // The purge cron scans by expiry.
        "CREATE INDEX idx_geocode_cache_expires ON geocode_cache (expires_at)",
      ],
    });
    app.save(geocodeCache);

    // ── idempotency_keys ──────────────────────────────────────────────────
    // The keystone of the online-only decision.
    //
    // A visit is one transaction through one endpoint, and the field conditions
    // are exactly the ones that make a write ambiguous: a stairwell with no
    // signal, a phone that sleeps mid-request. The client cannot know whether a
    // timed-out POST landed, so it retries — and without this table the retry
    // writes the visit twice, which in this domain means a nest recorded as
    // swapped twice and a rhythm advanced twice.
    //
    // So the client generates ONE key per logical operation, reuses it for every
    // retry, and the server replays the stored response instead of writing
    // again.
    const idempotencyKeys = new Collection({
      type: "base",
      name: "idempotency_keys",
      fields: [
        // 32 hex chars, 128 bits of secure randomness. See newIdempotencyKey.
        { name: "key", type: "text", required: true, max: 64 },
        // Scoped per user as well as per key, so one member's retry can never
        // replay another's response — even in the impossible case of a
        // collision.
        { name: "user", type: "text", required: true, max: 40 },
        // Which route this key belongs to, so the same key on a different
        // endpoint is a different operation rather than a spurious replay.
        { name: "route", type: "text", required: true, max: 120 },
        // The response to replay, verbatim.
        { name: "response", type: "json", required: false, maxSize: 200000 },
        { name: "status", type: "number", required: false },
        { name: "expires_at", type: "text", required: true, max: 40 },
        { name: "created", type: "autodate", onCreate: true, onUpdate: false },
        { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
      ],
      indexes: [
        'CREATE UNIQUE INDEX idx_idempotency_user_route_key' +
          ' ON idempotency_keys (user, route, key)',
        "CREATE INDEX idx_idempotency_expires ON idempotency_keys (expires_at)",
      ],
    });
    app.save(idempotencyKeys);
  },
  (app) => {
    for (const name of ["geocode_cache", "idempotency_keys"]) {
      app.delete(app.findCollectionByNameOrId(name));
    }
  },
);
