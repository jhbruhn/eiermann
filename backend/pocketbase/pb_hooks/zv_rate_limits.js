/// <reference path="../pb_data/types.d.ts" />

// The ONE writer of `settings.rateLimits` (federfall-0tf, -sjtg, -ds0d).
//
// PocketBase's own limiter is configured through settings, so every budget an
// app wants has to be merged into a single stored ruleset. Two hooks each
// rewriting that list is how a rule gets silently dropped — which is why this
// is one module with one entry point, and why an app registers it once:
//
//   onBootstrap((e) =>
//     require(`${__hooks}/zv_rate_limits.js`).apply(e, {
//       envPrefix: "EIERMANN",
//       groups: [
//         {
//           name: "geocode",
//           labels: [
//             "GET /api/eiermann/geocode",
//             "GET /api/eiermann/geocode/",
//           ],
//           maxEnv: "GEOCODE_RATE_MAX",
//           windowEnv: "GEOCODE_RATE_WINDOW",
//           maxDefault: 30,
//           windowDefault: 60,
//         },
//       ],
//     }),
//   );
//
// WHICH routes need a budget is the app's — it depends on which of them spawn a
// subprocess or relay to a third party. The merge, the factory-default restore
// and the label rules are not.
//
// ── Every label must be METHOD-QUALIFIED, and that is load-bearing ──────────
//
// PocketBase treats a label ending in "/" as a path PREFIX and anything else as
// a complete path — but a bare prefix is NOT enough, because matching is not
// longest-prefix-wins. Probed against 0.39.8: for each search label
// ("GET <path>" first, then "<path>") an exact rule wins, and failing that the
// FIRST prefix rule in stored order does. The factory `/api/` default is a
// prefix rule stored ahead of anything added here, so a bare
// "/api/<service>/geocode/" silently loses to it and budgets NOTHING — a
// federfall route was dead that way for a whole issue's lifetime, leaving
// reverse geocoding on the 300-per-10s general default while the comment beside
// it claimed otherwise.
//
// "GET /api/<service>/…" is matched against the FIRST search label, which
// "/api/" cannot prefix (it starts with "GET "), so the order of the stored
// list stops mattering.
//
// ── Why the factory defaults are restored on every boot ────────────────────
// An earlier version of this code built the ruleset from a "clean slate",
// discarding PocketBase's inactive factory defaults on its way to enabling the
// limiter — shipping instances whose ONLY throttled paths were its own routes,
// i.e. no brute-force brake on auth-with-password at all. Any instance that
// ever booted that version has the defaults gone from its STORED settings, so
// preserving what is there is not enough: every factory rule whose label is
// absent is put back. To neuter one deliberately, raise its maxRequests — a
// deleted default comes back on the next boot. An operator's own edit under a
// factory label wins, because the restore only fills in missing labels.
//
// ── Env ────────────────────────────────────────────────────────────────────
//   <P>_RATE_LIMITS_DISABLED  "1" to leave settings.rateLimits entirely alone
//                             (for an instance limited at the proxy)
//   plus each group's own max/window variables.
//
// Disabling ONE group removes its rules rather than leaving the last applied
// ones stored, but does not touch the limiter itself or the factory defaults —
// opting out of one budget must not be a way to lose the brute-force brake by
// accident. That is what the disable variable is for, and it is deliberately
// the only way to get there.
//
// ── The limiter keys on client IP ──────────────────────────────────────────
// Not on the authenticated user, even for auth-only routes. Behind a reverse
// proxy that IP is the proxy's own unless the trusted-proxy headers are set
// (zv_settings.js) — without it a budget is shared by ALL users instead of per
// client. It also means one account spread over many addresses is not what this
// stops; it raises the cost of a loop, it is not an authorization boundary.

/** PocketBase 0.39's factory defaults, probed from a pristine instance. */
const FACTORY_RULES = [
  { label: "*:auth", audience: "", duration: 3, maxRequests: 2 },
  { label: "*:create", audience: "", duration: 5, maxRequests: 20 },
  { label: "/api/batch", audience: "", duration: 1, maxRequests: 3 },
  { label: "/api/", audience: "", duration: 10, maxRequests: 300 },
];

/**
 * Merges the app's budgets into `settings.rateLimits`. Call from onBootstrap
 * AFTER `e.next()`.
 *
 * @param config {envPrefix, groups:[{name, labels, maxEnv, windowEnv,
 *               maxDefault, windowDefault, legacyLabels}]}
 *               `legacyLabels` are labels an earlier version of the app stored
 *               and that must be cleaned out — inert, but left alone they sit
 *               in the settings forever looking like a budget.
 */
function apply(e, config) {
  const prefix = String((config && config.envPrefix) || "");
  const groupsIn = (config && config.groups) || [];
  const logPrefix = prefix.toLowerCase() + ": ";

  if ($os.getenv(prefix + "_RATE_LIMITS_DISABLED") === "1") {
    e.app
      .logger()
      .warn(
        logPrefix +
          "rate limits not applied (" +
          prefix +
          "_RATE_LIMITS_DISABLED)",
      );
    return;
  }

  const num = (key, fallback) => {
    const raw = $os.getenv(prefix + "_" + key);
    const n = parseInt(raw && raw !== "" ? raw : "", 10);
    return isNaN(n) ? fallback : n;
  };
  const windowOf = (key, fallback) => {
    const n = num(key, fallback);
    return n <= 0 ? fallback : n;
  };

  const groups = groupsIn.map((g) => ({
    name: String(g.name),
    labels: g.labels || [],
    maxRequests: num(g.maxEnv, g.maxDefault),
    duration: windowOf(g.windowEnv, g.windowDefault),
  }));

  // Every label this hook owns, whether or not it ends up applied — a group
  // that is switched off has to have its stored rules dropped too.
  const ours = [];
  for (let i = 0; i < groupsIn.length; i++) {
    const legacy = groupsIn[i].legacyLabels || [];
    for (let j = 0; j < legacy.length; j++) ours.push(String(legacy[j]));
  }
  for (let i = 0; i < groups.length; i++) {
    for (let j = 0; j < groups[i].labels.length; j++) {
      ours.push(String(groups[i].labels[j]));
    }
  }

  const settings = e.app.settings();
  const others = (settings.rateLimits.rules || []).filter(
    (r) => ours.indexOf(String(r.label)) < 0,
  );

  const present = others.map((r) => String(r.label));
  const restored = FACTORY_RULES.filter((d) => present.indexOf(d.label) < 0);

  let applied = others.concat(restored);
  const enabled = [];
  for (let i = 0; i < groups.length; i++) {
    const g = groups[i];
    if (g.maxRequests <= 0) continue; // explicit opt-out
    applied = applied.concat(
      g.labels.map((l) => ({
        label: l,
        audience: "",
        duration: g.duration,
        maxRequests: g.maxRequests,
      })),
    );
    enabled.push(g.name + "=" + g.maxRequests + "/" + g.duration + "s");
  }

  settings.rateLimits.enabled = true;
  settings.rateLimits.rules = applied;
  e.app.save(settings);
  e.app
    .logger()
    .info(
      logPrefix + "rate limits applied",
      "budgets",
      enabled.length > 0 ? enabled.join(" ") : "none (defaults only)",
    );
}

/**
 * Whether [label] will actually be reached, given PocketBase's matching.
 *
 * A label that is neither method-qualified nor an exact path is a budget that
 * silently does nothing — the trap in the header. Exported so an app's own test
 * can assert its group list rather than discovering it in production.
 */
function labelIsReachable(label) {
  const s = String(label);
  if (/^[A-Z]+ \//.test(s)) return true; // method-qualified: always reached
  return !s.endsWith("/"); // a bare prefix loses to the factory /api/ rule
}

module.exports = {
  apply: apply,
  labelIsReachable: labelIsReachable,
  FACTORY_RULES: FACTORY_RULES,
};
