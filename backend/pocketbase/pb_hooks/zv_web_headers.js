/// <reference path="../pb_data/types.d.ts" />

// Security headers for a Flutter WASM SPA served by PocketBase, and for the
// files it uploads.
//
// Usage — an app's `web_headers.pb.js` is a wrapper, because `routerUse` has to
// be called at load time while the callback runs in an isolated JSVM:
//
//   routerUse((e) =>
//     require(`${__hooks}/zv_web_headers.js`).apply(e, { envPrefix: "EIERMANN" }),
//   );
//
// ── Content-Security-Policy (federfall-jfe) ─────────────────────────────────
//
// A web build stores its auth token in localStorage (federfall-xe9), so XSS is
// the attack that matters — CSP is the mitigation that caps its blast radius.
// A Zugvogel SPA is fully same-origin by construction: built with
// --no-web-resources-cdn (no gstatic canvaskit), index.html loads
// flutter_bootstrap.js as an external file (no inline script), the fonts are
// bundled assets (zugvogel_ui ships them — the engine would otherwise download
// Roboto from fonts.gstatic.com at startup), and the API is the serving origin
// itself. The only cross-origin traffic left is map tiles.
//
// The engine also fetches per-glyph Noto FALLBACK fonts for codepoints no
// bundled font covers, from fonts.gstatic.com — this policy blocks that, and
// the engine re-queues the failed download on every layout of that text, so one
// stray glyph is an endless stream of console errors plus boxes on screen
// (federfall-sbtx). zugvogel_ui therefore bundles the fallbacks a European app
// realistically needs. Remaining gap by choice: CJK/Arabic/Indic text would add
// ~12 MB of assets, so it still hits this policy and renders as boxes. An
// operator serving such text can set `<PREFIX>_CSP` and append
// https://fonts.gstatic.com to font-src/connect-src — at the cost of a
// per-glyph request to Google.
//
//   script-src 'self' 'wasm-unsafe-eval'  wasm-unsafe-eval is what lets the
//                                         browser instantiate the dart2wasm /
//                                         skwasm modules; no eval, no inline.
//   style-src  'unsafe-inline'            the Flutter engine injects its style
//                                         elements at runtime — required.
//   img-src / connect-src + tile origins  flutter_map fetches tiles as images
//                                         (JS renderer) or via fetch (wasm).
//   connect-src blob:                     image_picker_for_web hands the picked
//                                         file back as a blob: URL; reading its
//                                         bytes is a fetch of that URL. blob:
//                                         URLs are minted by the page itself
//                                         and origin-bound, so this allows
//                                         nothing cross-origin.
//   worker-src 'self' blob:               skwasm's render workers.
//   frame-ancestors 'none'                no embedding → no clickjacking.
//
// Env, all under the app's own prefix:
//   <P>_MAP_TILE_URL      the runtime map source zv_info.js serves
//   <P>_MAP_STYLE_URL     (federfall-el1f). Their ORIGINS are added to the
//                         policy automatically, so prescribing a tile server
//                         cannot leave the browser blocking the very tiles the
//                         server asked for. Read here only for that derivation
//                         — zv_info.js owns whether the config is complete
//                         enough to hand out.
//   <P>_MAP_TILE_ORIGINS  comma list of extra tile-server origins to allow,
//                         replacing the two shipped defaults
//                         (https://tiles.openfreemap.org for vector,
//                         https://tile.openstreetmap.org for raster) — the
//                         fallback an app uses when the server prescribes
//                         nothing, so they stay allowed unless you say
//                         otherwise. Still needed when a style's own
//                         sprite/glyph/tile hosts live on a DIFFERENT origin
//                         than the style JSON, which no derivation from the URL
//                         can know.
//   <P>_CSP               full replacement policy for the SPA, for operators
//                         whose setup needs more; "off" disables the header
//                         entirely. Read the warning on
//                         zugvogel_pb_client's PrefsAuthTokenStorage before
//                         using it: the CSP is load-bearing for the web token
//                         storage decision, not defence in depth.
//
// Uploaded files (/api/files/…) get their own lockdown header: `sandbox` +
// default-src 'none' means a file that slips past the upload MIME allowlist and
// is opened inline still cannot run script against the app origin; nosniff
// stops MIME guessing on top.
//
// ── Cross-origin isolation (COOP/COEP) ──────────────────────────────────────
//
// A `flutter build web --wasm` bundle's skwasm renderer wants a
// cross-origin-isolated context to use threads (SharedArrayBuffer), which the
// browser only grants when the document is served with COOP + COEP. Set here so
// a single-container stack — PocketBase serving the SPA from --publicDir —
// needs no reverse proxy.
//
// COEP value = "credentialless" (not "require-corp") on purpose: the app loads
// cross-origin map tiles, and require-corp would BLOCK any cross-origin
// subresource that does not send CORP/CORS headers. credentialless still
// enables crossOriginIsolated but fetches such no-cors resources without
// credentials, so the public tiles keep loading. Everything else the app needs
// (API, /api/files images, the wasm/canvaskit assets) is same-origin.
//
// Graceful by design: a browser without credentialless support simply is not
// isolated, and Flutter falls back to the single-threaded renderer — the app
// still works, just without the threaded fast path.
//
// Scope: only the SPA. The PocketBase REST API (/api/…) and Admin UI (/_/…) are
// left untouched, so isolation can never interfere with them.

/** Scheme + host + port of a configured map URL, or "". */
function originOf(raw) {
  // A raster template is not a parseable URL ({z}/{x}/{y} braces), so match the
  // origin off the front rather than handing the whole thing to a URL parser.
  const m = /^(https?:\/\/[^/?#]+)/i.exec((raw || "").trim());
  return m ? m[1] : "";
}

/**
 * The default policy, with [tiles] (a space-joined origin list) allowed.
 *
 * Exported so a test can assert on it without a live server.
 */
function defaultCsp(tiles) {
  return [
    "default-src 'self'",
    "script-src 'self' 'wasm-unsafe-eval'",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' blob: data: " + tiles,
    "font-src 'self'",
    "connect-src 'self' blob: " + tiles,
    "worker-src 'self' blob:",
    "object-src 'none'",
    "base-uri 'self'",
    "frame-ancestors 'none'",
    "form-action 'self'",
  ].join("; ");
}

/** The tile origins to allow, from the env under [prefix]. */
function tileOrigins(prefix) {
  const env = (name) => $os.getenv(String(prefix) + "_" + name) || "";
  const listed = (
    env("MAP_TILE_ORIGINS") ||
    "https://tiles.openfreemap.org,https://tile.openstreetmap.org"
  )
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s !== "");
  const derived = [
    originOf(env("MAP_TILE_URL")),
    originOf(env("MAP_STYLE_URL")),
  ].filter((s) => s !== "");
  return listed
    .concat(derived)
    .filter((s, i, all) => all.indexOf(s) === i)
    .join(" ");
}

/** Sets the headers for this request and calls `e.next()`. */
function apply(e, config) {
  const prefix = (config && config.envPrefix) || "";
  const path = e.request.url.path;

  // Uploaded files: never let a served file act as a document of this origin.
  if (path.startsWith("/api/files/")) {
    const h = e.response.header();
    h.set("Content-Security-Policy", "default-src 'none'; sandbox");
    h.set("X-Content-Type-Options", "nosniff");
    return e.next();
  }

  if (!path.startsWith("/api/") && !path.startsWith("/_/")) {
    const h = e.response.header();
    h.set("Cross-Origin-Opener-Policy", "same-origin");
    h.set("Cross-Origin-Embedder-Policy", "credentialless");

    const cspEnv = $os.getenv(prefix + "_CSP") || "";
    if (cspEnv.toLowerCase() !== "off") {
      h.set("Content-Security-Policy", cspEnv || defaultCsp(tileOrigins(prefix)));
    }
    h.set("X-Content-Type-Options", "nosniff");
    // strict-origin-when-cross-origin (the modern browser default): same-origin
    // requests keep the full URL (harmless — it is our own origin), cross-origin
    // ones send the bare origin, and an https→http downgrade sends nothing.
    //
    // NOT "same-origin" (federfall-txxj), which sent no Referer cross-origin at
    // all: on web the ONLY cross-origin traffic is map tiles, and a browser
    // forbids scripts from setting User-Agent, so flutter_map's
    // userAgentPackageName does not apply there. With the Referer stripped too,
    // tile requests carried NO identification whatsoever — exactly the shape
    // the OSM Tile Usage Policy says may be blocked, and it was: 403s on the
    // web app while the Android build (which can send its own UA) was fine.
    // The origin is the identification, and no path — so a record's URL never
    // leaves this origin either way.
    h.set("Referrer-Policy", "strict-origin-when-cross-origin");
    // Deny everything except the device features photo capture and location
    // tagging actually use, and only for this origin (no iframes).
    h.set(
      "Permissions-Policy",
      "camera=(self), geolocation=(self), microphone=(), " +
        "payment=(), usb=(), magnetometer=(), gyroscope=()",
    );
  }
  return e.next();
}

module.exports = {
  apply: apply,
  defaultCsp: defaultCsp,
  tileOrigins: tileOrigins,
  originOf: originOf,
};
