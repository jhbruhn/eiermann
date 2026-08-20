/// <reference path="../pb_data/types.d.ts" />

// federfall-7nf.1 — server identity & capability discovery.
//
// Usage — the app's `info.pb.js` owns the ROUTE, because the path carries its
// own service name:
//
//   routerAdd("GET", "/api/eiermann/info", (e) =>
//     require(`${__hooks}/zv_info.js`).respond(e, {
//       service: "eiermann",
//       envPrefix: "EIERMANN",
//       defaultName: "Eiermann",
//     }),
//   );
//
// `GET /api/<service>/info` is UNAUTHENTICATED and is how the app verifies, on
// first run, that a URL points at a genuine backend OF ITS OWN — not some other
// host that merely answers /api/health with a 200, and not the *other* Zugvogel
// app's server. It also tells the login screen which auth options the server
// actually offers, so the UI can adapt.
//
// The response carries:
//   service / <service>  — the identity marker the client requires before it
//                          will accept the server (a generic PocketBase has no
//                          such route → 404 → "not this app's server"). The
//                          key is named after the service for the same reason
//                          the route is: it is what makes the two apps
//                          distinguishable.
//   version              — major.minor only (patch withheld from this
//                          unauthenticated endpoint), for display + diagnostics.
//   minClient            — oldest client build this server still serves,
//                          derived from the running major; see below.
//   name                 — branding/instance name shown on the login screen.
//   auth                 — enabled auth methods, derived from live PB config.
//   map                  — optional runtime map source override
//                          (federfall-el1f), omitted unless the operator
//                          configured a complete one. May carry the tile
//                          provider's apiKey, which this UNAUTHENTICATED
//                          endpoint therefore makes public — see below.
//
// PocketBase runs each route handler in an isolated JSVM context, so it cannot
// see file-level helpers — which is why the app's wrapper builds its config
// literal INSIDE the handler and this module is required there too.

/**
 * Answers the discovery request.
 *
 * @param config {service, envPrefix, defaultName, selfSignup}
 *               `selfSignup` defaults to false: a Zugvogel instance is
 *               invite-only, users are created by supervisors.
 */
function respond(e, config) {
  const service = String(config.service);
  const prefix = String(config.envPrefix);
  const env = (name) => $os.getenv(prefix + "_" + name) || "";
  const logPrefix = service + " info: ";

  // Sourced from the image env, set at build time from the release-please tag
  // — never hand-edited. Only major.minor is exposed below: the exact patch
  // level is deliberately withheld from this UNAUTHENTICATED endpoint so it
  // cannot be used to fingerprint whether a specific CVE fix is deployed. The
  // full version is still visible via the image tag/label for operator use.
  const VERSION = env("VERSION") || "0.0.0-dev";

  // `minClient` is the oldest client build this server still serves. It is
  // DERIVED from VERSION's major, because the major IS the app↔server wire
  // contract (federfall-1wm): every wire-breaking change is a `!` commit, which
  // bumps the major, so `<major>.0.0` is exactly the floor. federfall had it
  // hardcoded "1.0.0" while releases were still on 0.x — a floor above every
  // client in existence, which would have locked out all of them the moment
  // anything enforced it.
  //
  // `<P>_MIN_CLIENT` overrides it upward for the rarer case: a floor *within* a
  // major, e.g. "1.4.0" when older 1.x clients must not be served any more
  // despite the contract itself being unchanged.
  const major = parseInt(VERSION, 10);
  const MIN_CLIENT =
    env("MIN_CLIENT") || (isNaN(major) ? "0.0.0" : major + ".0.0");

  // Read live capabilities defensively — a missing/renamed field must never 500
  // the discovery endpoint, so every probe falls back to a safe default.
  let name = String(config.defaultName || service);
  let password = true;
  let oauth2 = [];
  let smtpEnabled = false;

  try {
    const settings = $app.settings();
    if (settings.meta && settings.meta.appName) name = settings.meta.appName;
    smtpEnabled = !!(settings.smtp && settings.smtp.enabled);
  } catch (err) {
    $app.logger().warn(logPrefix + "settings read failed", "err", err);
  }

  try {
    const users = $app.findCollectionByNameOrId("users");
    if (users.passwordAuth) password = !!users.passwordAuth.enabled;
    if (users.oauth2 && users.oauth2.enabled) {
      oauth2 = (users.oauth2.providers || []).map((p) => p.name);
    }
  } catch (err) {
    $app.logger().warn(logPrefix + "users collection read failed", "err", err);
  }

  // Resetting a password only makes sense when password sign-in itself is
  // enabled — otherwise SMTP being configured (e.g. for an OIDC-only instance)
  // made this true with no password form to show the link on.
  const passwordReset = password && smtpEnabled;

  // Derived, not configured: asking for the groups scope is exactly what
  // configuring a group mapping implies, so there is no separate env for it to
  // drift out of sync with (an operator who has to restate the scope list by
  // hand is one `openid` away from breaking sign-in entirely).
  //
  // PocketBase hardcodes its own minimal OIDC scopes (openid/email/profile) and
  // offers no way to widen them server-side — upstream's position is that scopes
  // belong to the client, which builds the authorization URL (pocketbase#3727,
  // pocketbase/discussions#7114). So the server can only PRESCRIBE them here
  // and let the app apply them, in place of the ones PocketBase built.
  const groupsEnv = [
    "OIDC_SUPERVISOR_GROUP",
    "OIDC_COORDINATOR_GROUP",
    "OIDC_CARER_GROUP",
    "OIDC_ALLOWED_GROUPS",
  ];
  let groupsConfigured = false;
  for (let i = 0; i < groupsEnv.length; i++) {
    if (env(groupsEnv[i]) !== "") groupsConfigured = true;
  }
  // The scope is named after the claim it releases — the same value the
  // provisioning hook reads the groups out of.
  const groupsClaim = env("OIDC_GROUPS_CLAIM") || "groups";

  const oauth2Scopes = {};
  if (groupsConfigured) {
    for (let i = 0; i < oauth2.length; i++) {
      // Generic OIDC only (PocketBase names those oidc/oidc2/oidc3). Group
      // mapping is an OIDC feature, and handing an unknown scope to a social
      // provider like Google fails the whole authorization request.
      if (oauth2[i].indexOf("oidc") !== 0) continue;
      const scopes = ["openid", "email", "profile"];
      if (scopes.indexOf(groupsClaim) < 0) scopes.push(groupsClaim);
      oauth2Scopes[oauth2[i]] = scopes;
    }
  }

  // Runtime map source override (federfall-el1f). Which tile server the app
  // talks to is otherwise a build-time dart-define baked into the web bundle and
  // the APK, so a self-hoster running the published image could not point the
  // maps anywhere else without forking and rebuilding. The server may therefore
  // PRESCRIBE the source here; the app prefers it over its own defines and falls
  // back to them when this key is absent.
  //
  // Deliberately all-or-nothing: mode, the URL for that mode, and the
  // attribution must ALL be set or the whole block is dropped with a warning. A
  // half-applied override is the dangerous shape — rendering some other
  // provider's tiles under the built-in credit is a licensing problem, and there
  // is no per-mode default attribution the client could fall back to when only
  // the mode flips. attributionUrl stays optional: the visible credit is the
  // licence requirement, the link to a copyright page is only the OSMF's
  // recommendation.
  //
  // Note this does NOT have to be kept in sync with <P>_MAP_TILE_ORIGINS:
  // zv_web_headers.js derives the CSP origins from these same variables, so a
  // prescribed source is allowed by the policy automatically.
  let map = null;
  try {
    const trimmed = (k) => env(k).trim();
    const mode = trimmed("MAP_MODE").toLowerCase();
    const tileUrl = trimmed("MAP_TILE_URL");
    const styleUrl = trimmed("MAP_STYLE_URL");
    const attribution = trimmed("MAP_ATTRIBUTION");
    const attributionUrl = trimmed("MAP_ATTRIBUTION_URL");
    // Commercial providers key their tiles. Raster keys usually ride along in
    // the URL template already, but a vector style needs the key substituted
    // into the style's OWN source/sprite/glyph URLs (the {key} token), which
    // only the client can do while it reads the style — hence a field of its own
    // rather than something the operator can inline.
    //
    // NOTE this endpoint is UNAUTHENTICATED, so a key set here is readable by
    // anyone who can reach the server. That is not a step down from the
    // alternatives (a web bundle exposes its key to devtools, and a release APK
    // is a public download), but it does make extraction a single GET —
    // restrict the key by referrer/domain at the provider, and prefer a provider
    // whose free tier does not need one at all.
    const apiKey = trimmed("MAP_API_KEY");

    // Raster reads a {z}/{x}/{y} template, vector a MapLibre style JSON — only
    // the one matching the mode counts, so a leftover variable for the other
    // path can never half-apply.
    const url = mode === "raster" ? tileUrl : mode === "vector" ? styleUrl : "";
    const complete =
      url !== "" && attribution !== "" && /^https?:\/\//i.test(url);

    if (complete) {
      map = { mode: mode, attribution: attribution };
      if (mode === "raster") map.tileUrl = tileUrl;
      else map.styleUrl = styleUrl;
      if (attributionUrl !== "") map.attributionUrl = attributionUrl;
      if (apiKey !== "") map.apiKey = apiKey;
    } else if (
      mode ||
      tileUrl ||
      styleUrl ||
      attribution ||
      attributionUrl ||
      apiKey
    ) {
      // Something was set but the set is unusable — say so loudly, because the
      // symptom on the client is simply "my setting did nothing".
      $app
        .logger()
        .warn(
          logPrefix +
            "ignoring incomplete " +
            prefix +
            "_MAP_* config; set " +
            prefix +
            "_MAP_MODE to vector or raster, the matching " +
            prefix +
            "_MAP_STYLE_URL or " +
            prefix +
            "_MAP_TILE_URL to an http(s) URL, and " +
            prefix +
            "_MAP_ATTRIBUTION to the provider's required credit",
          "mode",
          mode,
          "url",
          url,
          "hasAttribution",
          attribution !== "",
        );
    }
  } catch (err) {
    $app.logger().warn(logPrefix + "map config read failed", "err", err);
  }

  const auth = {
    password: password,
    oauth2: oauth2,
    passwordReset: passwordReset,
    selfSignup: !!(config && config.selfSignup),
  };
  // Omitted entirely when no provider has an override, so the payload stays as
  // small as it was for the common case.
  if (Object.keys(oauth2Scopes).length > 0) auth.oauth2Scopes = oauth2Scopes;

  const body = {
    service: service,
    version: VERSION.split(".").slice(0, 2).join("."),
    minClient: MIN_CLIENT,
    name: name,
    auth: auth,
  };
  // The service-named boolean, alongside `service`. Two spellings of the same
  // marker so a client can check either; zugvogel_pb_client accepts both.
  body[service] = true;
  // Absent unless configured, so an unconfigured server's payload — and the
  // client behaviour it produces — is exactly what it was before.
  if (map) body.map = map;

  return e.json(200, body);
}

module.exports = { respond: respond };
