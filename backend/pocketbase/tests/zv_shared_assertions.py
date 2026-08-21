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
