"""Assertions about the SHARED hooks' behaviour, run by each app's own suite.

── Why these live here and not in each app ─────────────────────────────────

zugvogel ships no migrations, deliberately: a migration is a per-app historical
fact. So it cannot boot a PocketBase instance, and every test in this repo is a
node unit test over a pure function. The integration-level behaviour of a shared
hook — does the CSP actually reach the response, does the rate limit actually
land in settings, does the geocode route actually answer 502 — can only be
observed from inside an app that has a schema.

That is not a reason to write those assertions twice. It is a reason to write
them ONCE, here, and have both apps run them against their own instance. The
second run is the valuable one: it is what catches an app passing the wrong
configuration into a library that is itself correct, which is a failure a unit
test in this repo cannot see. Two such bugs were found in one afternoon —
`foreignRelation` missing its `parentOrgFallbacks`, and `stampActor`'s update
semantics, where zugvogel's own unit test confidently asserted the wrong answer
and federfall's live suite disagreed.

── What belongs in here, and what does not ────────────────────────────────

A property of a zv_ library. NOT an app's own rules: which of federfall's
collections a carer may delete from is federfall's business and belongs in
federfall's suite, even though it happens to involve the shared authorship
stamper.

Anything an app legitimately differs on is a PARAMETER, stated at the call site
where a reader can see it — the env prefix, the service name, which collection
holds the uploaded files, which rate-limit groups exist.

── Calling convention ─────────────────────────────────────────────────────

Each function takes `check(name, ok, detail="")` as its first argument, because
the two suites do not share one: eiermann uses `h.check` from zv_harness, and
federfall has its own module-level `check` predating it. Passing the callable in
costs one argument and means neither suite has to change how it reports.

    import zv_shared_assertions as shared
    shared.web_headers(check, BASE, files_path=f"/api/files/cases/{cid}/x.png")
"""

import urllib.error
import urllib.request


def _headers(base_url, path):
    """Response headers for a GET, whatever the status.

    A 404 carries the headers this module is about just as a 200 does, which is
    why the request is allowed to fail: asserting the sandbox CSP on an uploaded
    file does not require an uploaded file to exist.
    """
    request = urllib.request.Request(base_url + path, method="GET")
    try:
        return dict(urllib.request.urlopen(request).headers)
    except urllib.error.HTTPError as error:
        return dict(error.headers)
    except urllib.error.URLError:
        return {}


def web_headers(
    check,
    base_url,
    files_path,
    *,
    configured_raster="https://raster.invalid",
    configured_vector="https://vector.invalid",
    api_key="test-map-key",
    default_raster="https://tile.openstreetmap.org",
    default_vector="https://tiles.openfreemap.org",
):
    """zv_web_headers: the CSP, the isolation headers and their scope.

    [files_path] is any path under `/api/files/` — it need not exist. The
    `configured_*` and `api_key` values are what the caller's harness put in the
    environment, so the derivation can be checked rather than assumed.
    """
    file_headers = _headers(base_url, files_path)
    check(
        "uploaded files get the sandbox CSP",
        file_headers.get("Content-Security-Policy") == "default-src 'none'; sandbox",
        file_headers.get("Content-Security-Policy"),
    )
    check(
        "uploaded files get nosniff",
        file_headers.get("X-Content-Type-Options") == "nosniff",
    )
    check(
        "uploaded files get NO Referrer/Permissions-Policy",
        "Referrer-Policy" not in file_headers
        and "Permissions-Policy" not in file_headers,
        f"{file_headers.get('Referrer-Policy')}/"
        f"{file_headers.get('Permissions-Policy')}",
    )

    api_headers = _headers(base_url, "/api/health")
    check(
        "API responses carry NO SPA CSP",
        "Content-Security-Policy" not in api_headers,
        api_headers.get("Content-Security-Policy"),
    )

    spa = _headers(base_url, "/")
    csp = spa.get("Content-Security-Policy") or ""
    check("the SPA gets the CSP", csp.startswith("default-src 'self'"), csp)
    check(
        "the SPA CSP allows wasm and blocks embedding",
        "'wasm-unsafe-eval'" in csp and "frame-ancestors 'none'" in csp,
        csp,
    )
    check(
        "the SPA CSP lets connect-src read picked-image blobs",
        "connect-src 'self' blob:" in csp,
        csp,
    )
    check(
        "the SPA CSP allows the default raster tile origin",
        default_raster in csp,
        csp,
    )
    check(
        "the SPA CSP allows the default vector style origin",
        default_vector in csp,
        csp,
    )

    # The policy derives its origins from the CONFIGURED map URLs, so a
    # server-prescribed tile source cannot be blocked by the very policy that
    # server sent. The alternative relocates the footgun into "keep these two
    # unrelated variables consistent".
    check(
        "the SPA CSP derives the prescribed raster tile origin",
        configured_raster in csp,
        csp,
    )
    check(
        "the SPA CSP derives the configured vector style origin",
        configured_vector in csp,
        csp,
    )
    check(
        "derived origins do not leak the URL path or template",
        "{z}" not in csp and "style.json" not in csp,
        csp,
    )
    # A key lives in the query string of a tile URL, and the derivation cuts at
    # the origin — so it cannot reach a header sent to every visitor.
    check(
        "derived origins carry no query string (no API key in the header)",
        api_key not in csp and "?" not in csp,
        csp,
    )

    check(
        "the SPA keeps COOP/COEP isolation",
        spa.get("Cross-Origin-Opener-Policy") == "same-origin"
        and spa.get("Cross-Origin-Embedder-Policy") == "credentialless",
        f"{spa.get('Cross-Origin-Opener-Policy')}/"
        f"{spa.get('Cross-Origin-Embedder-Policy')}",
    )
    # NOT "same-origin": that stripped the Referer from map tile requests, which
    # on web is the only identification they can carry (a browser forbids setting
    # User-Agent), and OSM answers 403 to such requests.
    check(
        "the SPA gets Referrer-Policy: strict-origin-when-cross-origin",
        spa.get("Referrer-Policy") == "strict-origin-when-cross-origin",
        spa.get("Referrer-Policy"),
    )
    permissions = spa.get("Permissions-Policy") or ""
    check(
        "the SPA Permissions-Policy allows camera/geolocation for self only",
        "camera=(self)" in permissions and "geolocation=(self)" in permissions,
        permissions,
    )
    check(
        "the SPA Permissions-Policy denies microphone",
        "microphone=()" in permissions,
        permissions,
    )


def geocode_validation(check, req, service, token):
    """zv_geocode_route: what it refuses, and what it lets through to fail.

    [req] is the caller's request helper, `(method, path, token) -> (status,
    body)`. [service] is the path segment, so `/api/<service>/geocode`.

    Assumes the harness points the upstream at an unreachable address — every
    app's does, and it is what makes half of this meaningful: a well-formed pin
    must fail at the UPSTREAM (502), not at validation (400). Asserted on the
    BODY and not the status alone, because an unreachable upstream USED to
    surface as a bare 400 from an uncaught `$http.send` throw, and a status-only
    check passed for the wrong reason on every one of these.
    """
    base = f"/api/{service}/geocode"

    status, _ = req("GET", base, token)
    check("geocode without q is rejected", status == 400, f"status {status}")
    status, _ = req("GET", base + "?q=" + "x" * 300, token)
    check("geocode with overlong q is rejected", status == 400, f"status {status}")

    def reverse(pin):
        status, body = req("GET", f"{base}/reverse?lat={pin}", token)
        return status, (body or {}).get("error")

    # The reverse route once validated the PARSED coordinate and forwarded the
    # RAW string, so "52.5abc" survived parseFloat + isFinite, was cache-keyed as
    # "52.50000", and was relayed upstream verbatim: two different upstream
    # queries sharing one cache entry, whichever landed first winning it.
    for bad in (
        "52.5abc&lon=13.4",
        "52.5&lon=13.4abc",
        "abc&lon=13.4",
        "&lon=13.4",
        "NaN&lon=13.4",
        "Infinity&lon=13.4",
    ):
        status, error = reverse(bad)
        check(
            f"reverse geocode rejects lat={bad.split('&')[0]!r}",
            status == 400 and error in ("invalid lat/lon", "missing lat/lon"),
            f"{status} {error}",
        )
    status, error = reverse("91&lon=13.4")
    check(
        "reverse geocode rejects an out-of-range latitude",
        status == 400 and error == "invalid lat/lon",
        f"{status} {error}",
    )

    # The non-vacuous half. Exponent form counts as well-formed because Dart's
    # `double.toString()` emits it.
    for good in ("52.5&lon=13.4", "-52.5&lon=-13.4", "52.50000&lon=13.40000",
                 "1e-7&lon=13.4"):
        status, error = reverse(good)
        check(
            f"...while lat={good.split('&')[0]!r} reaches the geocoder",
            status == 502 and error == "geocoder unavailable",
            f"{status} {error}",
        )

    status, body = req("GET", base + "?q=Berlin", token)
    check(
        "an unreachable geocoder is 502 on the forward route too",
        status == 502 and (body or {}).get("error") == "geocoder unavailable",
        f"{status} {body}",
    )


def geocode_walled_off(check, req, service, token):
    """zv_geocode_route: a walled-off role cannot drive the geocoder.

    Only for an app that HAS such a role. A role walled off from every
    collection could still burn the upstream budget, and that is the one thing an
    access rule cannot stop, because there is no record to scope. The check runs
    before any upstream call, so a well-formed query never leaves the building.
    """
    base = f"/api/{service}/geocode"
    status, _ = req("GET", base + "?q=Berlin", token)
    check("a walled-off role CANNOT use forward geocode", status == 403,
          f"status {status}")
    status, _ = req("GET", base + "/reverse?lat=52.5&lon=13.4", token)
    check("a walled-off role CANNOT use reverse geocode", status == 403,
          f"status {status}")


def geocode_cache(check, req, service, token, seed, read_row):
    """zv_geocode_route: the cache — read path, key rounding and hit accounting.

    [seed] plants a row and returns its id; [read_row] fetches one by id. Both
    are the caller's, because `geocode_cache` has all-null API rules and only a
    superuser can touch it, and because expiry needs the caller's date helper.
    [seed] takes `(kind, key, response, days)` — negative days for an expired row.

    This is the only way the read path is observable at all: with no reachable
    geocoder there is no successful response to store, and `cachePut` swallows
    every error by design — so a cache that had silently stopped working (a
    module context that could not `new Record`, a drifted key) would look exactly
    like a cache that was never exercised. The upstream is unreachable here, so a
    200 can ONLY have come from the cache.
    """
    payload = {
        "result": {
            "lat": 52.5, "lon": 13.4, "displayName": "cached Berlin",
            "city": "Berlin", "region": "Berlin",
        }
    }
    row_id = seed("reverse", "52.50000,13.40000", payload, 1)

    def reverse(pin):
        return req("GET", f"/api/{service}/geocode/reverse?lat={pin}", token)

    status, body = reverse("52.5&lon=13.4")
    check(
        "a cached reverse lookup is served without reaching the geocoder",
        status == 200
        and ((body or {}).get("result") or {}).get("displayName") == "cached Berlin",
        f"{status} {body}",
    )
    # The ~1m rounding IS the key: a pin differing below the 5th decimal must
    # land on the same entry, and one differing above it must not.
    status, _ = reverse("52.500001&lon=13.4")
    check("...and a pin within a metre shares that entry", status == 200,
          f"status {status}")
    status, _ = reverse("52.6&lon=13.4")
    check("...while a different pin misses it and goes upstream", status == 502,
          f"status {status}")

    # Hit accounting is best-effort, and it is also the only proof the module can
    # WRITE this collection at all — a silently broken `save` here is what would
    # make the whole cache a no-op.
    row = read_row(row_id)
    check(
        "a cache hit is counted (the module can write the cache)",
        (row or {}).get("hits", 0) >= 2,
        f"hits={(row or {}).get('hits')}",
    )

    seed("reverse", "10.00000,10.00000", payload, -1)
    status, _ = reverse("10&lon=10")
    check("an expired cache row is a miss, not a stale answer", status == 502,
          f"status {status}")


def info(
    check,
    req,
    service,
    *,
    providers,
    self_signup,
    password_auth=True,
    oidc_groups_scope,
    map_mode="raster",
    map_tile_url="https://raster.invalid/{z}/{x}/{y}.png",
    map_attribution="© Test Tiles",
    map_api_key="test-map-key",
):
    """zv_info: server identity and capability discovery.

    Everything an app configures is a parameter, so the call site reads as a
    statement of what THIS instance was set up to be — and a wrong expectation
    fails here rather than being quietly matched.

    `oidc_groups_scope` is whether the harness configured an OIDC GROUP MAPPING.
    PocketBase hardcodes its OAuth2 scopes with no server-side way to widen them,
    so the server publishes the set the app should request instead, and it derives
    that from the mapping being present. An app with no mapping must NOT advertise
    the groups scope — asserted either way, because "no scope" and "scope absent
    because the whole block is missing" look identical from a distance.
    """
    status, body = req("GET", f"/api/{service}/info", None)
    check(f"GET /api/{service}/info is unauthenticated (200)", status == 200,
          f"status {status}")
    body = body or {}
    check(
        "carries the service identity marker, both spellings",
        body.get(service) is True and body.get("service") == service,
        body,
    )
    check(
        "reports a version and minClient",
        bool(body.get("version")) and bool(body.get("minClient")),
        body,
    )
    # The MAJOR is the app↔server wire contract, so minClient is DERIVED as
    # "<major>.0.0" — never a hand-set constant, which drifts above every client
    # in existence (it sat at "1.0.0" for all of 0.x).
    check(
        "minClient floors at the running major",
        body.get("minClient") == body.get("version", "").split(".")[0] + ".0.0",
        body,
    )

    auth = body.get("auth") or {}
    check("password auth matches the configuration",
          auth.get("password") is password_auth, auth)
    check("oauth2 is a list", isinstance(auth.get("oauth2"), list), auth)
    check("self-signup matches the configuration",
          auth.get("selfSignup") is self_signup, auth)
    check("the configured providers are advertised",
          set(auth.get("oauth2") or []) == set(providers), auth)

    scopes = auth.get("oauth2Scopes") or {}
    if oidc_groups_scope:
        check(
            "a group mapping makes OIDC request the groups scope",
            scopes.get("oidc") == ["openid", "email", "profile", "groups"],
            auth,
        )
    else:
        check(
            "with no group mapping, OIDC does NOT request the groups scope",
            "groups" not in (scopes.get("oidc") or []),
            auth,
        )
    # A social provider rejects the whole authorization request over an unknown
    # scope, and cannot do OIDC group mapping anyway.
    check("a social provider keeps PocketBase's own scopes",
          "google" not in scopes, auth)

    # The tile source is a build-time define in the app, so the server prescribes
    # one here for self-hosters running the published image.
    prescribed = body.get("map") or {}
    check(
        "the configured map source is prescribed",
        prescribed.get("mode") == map_mode
        and prescribed.get("tileUrl") == map_tile_url,
        prescribed,
    )
    # Only the URL for the ACTIVE mode: a leftover variable for the other
    # rendering path must not travel along and be read as the wrong thing.
    check("the other mode's URL is not prescribed",
          "styleUrl" not in prescribed, prescribed)
    # The credit travels with the URL or neither applies — tiles from one
    # provider under another's attribution is a licensing problem.
    check("the prescription carries its attribution",
          prescribed.get("attribution") == map_attribution, prescribed)
    check(
        "an unset attribution link stays absent, not a wrong copyright page",
        "attributionUrl" not in prescribed,
        prescribed,
    )
    # Commercial providers key their tiles, and a vector style needs the key
    # substituted into the style's own source and sprite URLs — only the client
    # can do that, so the key travels as its own field. This endpoint is public,
    # so a key set here IS public.
    check("the provider API key is handed to the client",
          prescribed.get("apiKey") == map_api_key, prescribed)
