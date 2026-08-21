"""The shared half of a Zugvogel backend rule/hook suite.

Imported by an app's own `test_rules.py`, which owns every assertion; this owns
the plumbing and the sweep helpers.

    from zv_harness import H, sweep_collections

    h = H()                       # reads ZV_TEST_URL / ZV_ADMIN_* from the env
    T = h.admin_token()
    h.check("a carer cannot delete an org", h.req("DELETE", ...)[0] >= 400)
    ...
    sys.exit(h.summary())

Why a class and not module globals: federfall's suite kept BASE, the counters
and the token in module scope, which works for exactly one suite per process.
An app that wants a second file (crons, or a slow group) then either re-reads
the env in both or shares mutable state between them. One object per run makes
that a non-question.
"""

import base64
import datetime
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# A real 1x1 PNG (RGBA, Pillow-encoded — CRC-correct), for exercising file-field
# uploads.
#
# The fixture this replaced decoded as an image fine everywhere it was only ever
# stored and served, but had a broken IDAT CRC that Typst's stricter PNG decoder
# rejected outright — which only surfaced once a report actually embedded a
# record's photo via `image()`, as "CRC error decoding IDAT chunk" in the
# container log. A photo from any real camera would never have this problem;
# only a hand-crafted fixture does. Use this one.
PNG_1X1 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4"
    "z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
)


class H:
    """One suite run: the base URL, the counters, and the request helpers."""

    def __init__(self, base=None, admin_email=None, admin_pass=None,
                 user_pass="Pass12345!"):
        self.base = base or os.environ.get("ZV_TEST_URL", "http://localhost:8090")
        self.admin_email = admin_email or os.environ.get("ZV_ADMIN_EMAIL", "")
        self.admin_pass = admin_pass or os.environ.get("ZV_ADMIN_PASS", "")
        self.user_pass = user_pass
        self.passed = 0
        self.failed = 0

    # ── reporting ──────────────────────────────────────────────────────────

    def check(self, name, ok, detail=""):
        if ok:
            self.passed += 1
            print(f"  \033[32mPASS\033[0m {name}")
        else:
            self.failed += 1
            print(f"  \033[31mFAIL\033[0m {name}  {detail}")
        return ok

    def summary(self):
        """Prints the tally and returns the exit code."""
        print(f"\n{self.passed} passed, {self.failed} failed")
        return 1 if self.failed else 0

    def fatal(self, *msg):
        """Setup could not complete. Exits 2, distinct from an assertion
        failure: a suite that could not even build its fixtures has not tested
        anything, and reporting that as "0 failures" would be a lie."""
        print("FATAL:", *msg)
        sys.exit(2)

    # ── requests ───────────────────────────────────────────────────────────

    def req(self, method, path, token=None, body=None, headers=None):
        """Returns (status, parsed_json_or_None).

        [headers] adds request headers — needed for anything a route reads off
        the request rather than out of the body, `Idempotency-Key` above all. A
        transactional endpoint's retry behaviour cannot be tested without it,
        and an untested retry is the one that writes the visit twice.
        """
        request_headers = {"Content-Type": "application/json"}
        if token:
            request_headers["Authorization"] = token
        for name, value in (headers or {}).items():
            if value is not None:
                request_headers[name] = value
        headers = request_headers
        data = json.dumps(body).encode() if body is not None else None
        r = urllib.request.Request(
            self.base + path, data=data, headers=headers, method=method
        )
        try:
            resp = urllib.request.urlopen(r)
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as e:
            raw = e.read().decode()
            try:
                return e.code, json.loads(raw)
            except Exception:
                return e.code, None

    def req_bytes(self, method, path, token=None):
        """Like [req], but for a binary response body — a PDF, a PNG.

        A separate helper rather than a mode flag, because `req`'s `.decode()`
        raises on PDF bytes: they are not valid UTF-8, and a suite that hits
        that gets a traceback instead of a failure.
        """
        headers = {}
        if token:
            headers["Authorization"] = token
        r = urllib.request.Request(self.base + path, headers=headers, method=method)
        try:
            resp = urllib.request.urlopen(r)
            return resp.status, resp.read(), dict(resp.headers)
        except urllib.error.HTTPError as e:
            return e.code, e.read(), dict(e.headers)

    def upload_file(self, method, path, token, field, filename, content_type,
                    blob):
        """Multipart upload of a single [blob] to [field]. (status, json)."""
        boundary = "----zvtestboundary"
        body = (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="{field}"; '
            f'filename="{filename}"\r\n'
            f"Content-Type: {content_type}\r\n\r\n"
        ).encode() + blob + f"\r\n--{boundary}--\r\n".encode()
        headers = {
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Authorization": token,
        }
        r = urllib.request.Request(
            self.base + path, data=body, headers=headers, method=method
        )
        try:
            resp = urllib.request.urlopen(r)
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as e:
            raw = e.read().decode()
            try:
                return e.code, json.loads(raw)
            except Exception:
                return e.code, None

    # ── auth and fixtures ──────────────────────────────────────────────────

    def admin_token(self):
        s, d = self.req(
            "POST",
            "/api/collections/_superusers/auth-with-password",
            body={"identity": self.admin_email, "password": self.admin_pass},
        )
        if s != 200:
            self.fatal("cannot authenticate superuser", s, d)
        return d["token"]

    def login(self, email, pw=None, attempts=6):
        """Signs in, waiting out the auth rate limit.

        PocketBase's FACTORY rate limit on `*:auth` is 2 requests per 3 seconds,
        and it is not something to turn off — it is the brute-force brake, and
        an instance that lost it ships without one (see zv_rate_limits.js).
        But a rule suite signs in a dozen times in a row, so without this the
        third login returns 429 with no token, and every assertion that needed
        that token fails for a reason having nothing to do with access rules.
        Diagnosing that from the failures alone is genuinely hard: an empty
        token reads as anonymous, and an anonymous LIST returns 200 with zero
        rows, which looks exactly like a rule that is too strict.

        So: back off and retry rather than special-casing the limit away.
        """
        for attempt in range(attempts):
            s, d = self.req(
                "POST",
                "/api/collections/users/auth-with-password",
                body={"identity": email, "password": pw or self.user_pass},
            )
            if s != 429:
                return (s, d["token"] if s == 200 else None)
            # The window is 3s; sleep just past it, growing slightly in case
            # several suites share the instance.
            time.sleep(1.5 * (attempt + 1))
        return (429, None)

    def mk(self, token, coll, body, attempts=6):
        """Creates a fixture record, or gives up. A failed fixture is not an
        assertion failure — everything after it would report nonsense.

        Backs off on 429 for the same reason [login] does, one limit further in.
        PocketBase's FACTORY rate limit on `*:create` is a burst budget, and a
        rule suite creates fixtures in exactly the shape it exists to stop: a
        dozen records back to back, in the same second. Turning the limit off is
        not the answer — it is a real brake, and an instance that ships without
        one has no protection against a client in a retry loop.

        Without the backoff the failure lands on whichever fixture happened to
        be the twenty-first, which is a function of how many tests came BEFORE
        it. So adding an unrelated assertion breaks a section it does not touch,
        the traceback names a collection whose rules are fine, and the suite
        gets a limit that shifts with its own length. That is the worst kind of
        flake: it looks like the new test found something.
        """
        for attempt in range(attempts):
            s, d = self.req(
                "POST", f"/api/collections/{coll}/records", token, body
            )
            if s != 429:
                break
            # Same shape as [login]'s wait: just past the window, growing in
            # case several suites share the instance.
            time.sleep(1.5 * (attempt + 1))
        if s != 200:
            self.fatal(f"failed to create {coll}: {s} {d}")
        return d

    def mkuser(self, token, email, role, org, active=True, extra=None):
        body = {
            "email": email,
            "password": self.user_pass,
            "passwordConfirm": self.user_pass,
            "role": role,
            "org": org,
            "is_active": active,
            "verified": True,
        }
        if extra:
            body.update(extra)
        return self.mk(token, "users", body)

    def listf(self, token, coll, flt):
        """The records [coll] returns for [flt] — an empty list on refusal.

        Asserting on a LIST is not the same as asserting on a view: PocketBase
        FILTERS a list rather than refusing it, so a leak here is a 200 with the
        row in it, not a 4xx. Both belong in any read test.
        """
        s, d = self.req(
            "GET",
            f"/api/collections/{coll}/records?filter=" + urllib.parse.quote(flt),
            token,
        )
        return d["items"] if s == 200 else []

    def reads_nothing(self, collection, token=None, record_id=None):
        """Whether [token] gets NO data out of [collection]. Use for a refusal.

        This exists because asserting `status >= 400` on a read is wrong half the
        time, and wrong in the direction that passes. PocketBase FILTERS a list
        rather than refusing it: an anonymous `GET /records` on a fully private
        collection returns **200 with an empty items array**. So a test that
        checks only the status code passes on a database that is completely
        public, and reports the security model as intact.
        
        A single-record view DOES refuse with a 4xx. Both shapes are handled
        here so a call site cannot pick the wrong one.
        """
        if record_id is not None:
            status, _ = self.req(
                "GET", f"/api/collections/{collection}/records/{record_id}", token
            )
            return status >= 400
        status, body = self.req("GET", f"/api/collections/{collection}/records", token)
        if status >= 400:
            return True
        return not ((body or {}).get("items") or [])

    @staticmethod
    def hook_scope_offenders(hooks_dir):
        """File-level bindings in `*.pb.js` under [hooks_dir], as `file:line`.

        Every PocketBase hook handler runs in its OWN JSVM context. A binding
        declared at file level is therefore not in scope inside the handler, and
        a handler that references one throws `ReferenceError: <name> is not
        defined` at REQUEST time — which PocketBase reports as a generic 400.

        That failure shape is why this is a sweep and not a code review. The
        file parses, the server boots without a word, the route registers, and
        nothing goes wrong until somebody calls it. eiermann's geocode proxy
        held a file-level `const config = () => ({...})` from the day it was
        written; it was found weeks later by curling the route, and the symptom
        was a 400 on a valid request — indistinguishable from bad input.

        So: put every helper behind `require(`${__hooks}/…`)` INSIDE the
        handler, and inline or re-require constants there too. Repeating a
        literal across three handlers is the price of the runtime.

        The `zv_*.js` libraries are exempt: they are modules, loaded by
        `require` into the handler's own context, where file-level bindings are
        exactly how a module is supposed to work.
        """
        import os
        import re

        # A declaration in column 0. Nested ones are inside something, and
        # inside something is where they belong.
        decl = re.compile(r"^(?:const|let|var|function|class)\s+([A-Za-z_$][\w$]*)")
        offenders = []
        for name in sorted(os.listdir(hooks_dir)):
            if not name.endswith(".pb.js"):
                continue
            path = os.path.join(hooks_dir, name)
            with open(path) as handle:
                for number, line in enumerate(handle, start=1):
                    match = decl.match(line)
                    if match:
                        offenders.append(f"{name}:{number} {match.group(1)}")
        return offenders

    @staticmethod
    def ok(status):
        """Whether [status] is a success.

        Spelled out because PocketBase answers a DELETE with **204**, not 200,
        and `status == 200` on a delete is a test that fails on a working
        server — which is worse than no test, because somebody then "fixes" the
        rule.
        """
        return 200 <= status < 300

    def collections(self, token):
        """Every collection the schema reports. The input to every sweep."""
        s, d = self.req("GET", "/api/collections?perPage=200", token)
        if s != 200 or not d:
            self.fatal("cannot list collections for a sweep", s)
        return d.get("items", [])

    @staticmethod
    def stamp(**delta):
        """A PocketBase-shaped UTC timestamp [delta] from NOW, e.g.
        `stamp(days=2)`.

        Relative rather than hard-coded, because what these tests exercise is a
        window around the SERVER's own clock: a literal stops meaning "the
        future" the day it passes, and the test then fails for a reason that has
        nothing to do with the code.
        """
        when = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(
            **delta
        )
        return when.strftime("%Y-%m-%d %H:%M:%S.000Z")


# ── Sweeps ─────────────────────────────────────────────────────────────────
#
# A sweep asks the LIVE SCHEMA a question and asserts the answer for every
# collection at once. It is the pattern that actually holds, and the reason is
# always the same: a hand-kept list of collections is a list somebody has to
# remember to extend, and the omission is invisible until the day it matters.
#
# In federfall a sampled list is exactly how `vet_appointments` shipped without
# the boundary guards its siblings had, and how eleven relation fields went
# unchecked while a hook guarded five.
#
# Write a sweep whenever the property is about a SHAPE rather than about a
# specific collection: "every rule that grants via a parent pins that parent",
# "every prose column is redacted in the audit log", "every relation whose
# target carries an org is org-scoped". A test per collection cannot express
# any of those about a collection that does not exist yet.


def client_writable(col):
    """Whether a client can send a body to [col] at all.

    Both rules null means hook-only: its rows are assembled server-side from a
    parent, so a client-write property cannot be violated there and asserting it
    would only add noise.
    """
    return not (col.get("createRule") is None and col.get("updateRule") is None)


def base_collections(cols, writable_only=True):
    """The base (non-view, non-auth) collections a sweep should look at."""
    out = [c for c in cols if c.get("type") == "base"]
    return [c for c in out if client_writable(c)] if writable_only else out


def fields_of(col, kind=None):
    """[col]'s fields, optionally filtered to one [kind] (e.g. "relation")."""
    fields = col.get("fields") or []
    return [f for f in fields if kind is None or f.get("type") == kind]


def rule_grants_via(rule, relation):
    """Whether [rule] grants access by traversing [relation].

    Top-level traversals only: `exam.case.org` grants via `exam`, not via
    `case`, so a dot-preceded segment does not count. Getting that wrong makes
    a sweep report every nested rule and get switched off.
    """
    return bool(re.search(rf"(?<![.\w]){re.escape(relation)}\.", rule or ""))


def missing_isset_guards(rule, fields):
    """Which of [fields] [rule] fails to pin with an `:isset = false` guard.

    A plain field reference in an UPDATE rule resolves against the STORED
    record, so a rule that grants through a parent relation also has to forbid
    CHANGING that relation — otherwise the grant is evaluated against the old
    parent while the new one is written.
    """
    return [f for f in fields if f"@request.body.{f}:isset = false" not in (rule or "")]


def sweep_collections(h, cols, name, predicate, writable_only=True):
    """Asserts [predicate] for every base collection, reporting all failures.

    [predicate] takes a collection and returns "" when it holds, or a reason.
    Every offender is named in one failure rather than one per collection, so a
    schema-wide slip reads as one problem.
    """
    offenders = []
    for col in base_collections(cols, writable_only=writable_only):
        reason = predicate(col)
        if reason:
            offenders.append(f"{col['name']}: {reason}")
    return h.check(name, not offenders, "; ".join(offenders))
