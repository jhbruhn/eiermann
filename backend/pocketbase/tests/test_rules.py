#!/usr/bin/env python3
"""eiermann-h7q.19 — backend rule & hook assertions against a running PocketBase.

Driven by run.sh, which provisions a throwaway instance. Standalone otherwise:

    ZV_TEST_URL=http://localhost:8091 ZV_ADMIN_EMAIL=… ZV_ADMIN_PASS=… \
    EIERMANN_COORD_EMAIL=… EIERMANN_COORD_PASS=… \
        PYTHONPATH=. python3 test_rules.py

The harness (request helpers, sweeps) is zugvogel's. Every assertion here is
this app's, and they are grouped by the PROPERTY they defend rather than by
collection — a rule matrix read collection-by-collection is a matrix nobody
re-reads.
"""
import os
import sys

from zv_harness import (
    H,
    base_collections,
    fields_of,
    missing_isset_guards,
    rule_grants_via,
    sweep_collections,
)

ORG = "org00000default"

h = H()
T = h.admin_token()

COORD_EMAIL = os.environ.get("EIERMANN_COORD_EMAIL", "coordinator@eiermann.local")
COORD_PASS = os.environ.get("EIERMANN_COORD_PASS", "CoordPass12345!")


# ── Fixtures ───────────────────────────────────────────────────────────────
#
# The coordinator is created by the bootstrap hook, not here: that hook IS the
# thing that makes a fresh instance administrable, so a suite that seeds its own
# coordinator would never exercise it.

print("[bootstrap]")
status, coord_token = h.login(COORD_EMAIL, COORD_PASS)
h.check(
    "the coordinator-bootstrap hook produced a usable account",
    status == 200 and coord_token is not None,
    f"status {status} — on a fresh data dir this is the ONLY way in, so a "
    f"failure here means a new instance cannot be administered at all",
)
if coord_token is None:
    h.fatal("no coordinator; every assertion below would be vacuous")

coord = h.req("POST", "/api/collections/users/auth-refresh", coord_token)[1]["record"]
h.check("...with the coordinator role", coord.get("role") == "coordinator", str(coord.get("role")))
h.check("...active", coord.get("is_active") is True)
h.check("...attached to the seeded organisation", coord.get("org") == ORG, str(coord.get("org")))

member = h.mk(
    coord_token,
    "users",
    {
        "email": "member@eiermann.test",
        "password": h.user_pass,
        "passwordConfirm": h.user_pass,
        "org": ORG,
        "role": "member",
        "is_active": True,
    },
)
_, member_token = h.login("member@eiermann.test")
h.check("a coordinator can create a member, who can then sign in", member_token is not None)

# A role-less account: what an OAuth2 self-registration produces before anybody
# has decided what it may do. The whole point of the walled-off state.
roleless = h.mk(
    coord_token,
    "users",
    {
        "email": "roleless@eiermann.test",
        "password": h.user_pass,
        "passwordConfirm": h.user_pass,
        "org": ORG,
        "is_active": True,
    },
)
h.req("PATCH", f"/api/collections/users/records/{roleless['id']}", T, {"role": None})
_, roleless_token = h.login("roleless@eiermann.test")


# ── Property 1: nothing is anonymous ───────────────────────────────────────
#
# Asserting on a LIST is not the same as asserting on a view. PocketBase FILTERS
# a list rather than refusing it, so an anonymous list returns 200 with an empty
# array — a leak here is a 200 WITH ROWS IN IT, not a 4xx. Checking the status
# code alone would have passed on a completely public database.

print("\n[nothing is readable anonymously]")
for collection in ("users", "organisations", "geocode_cache", "idempotency_keys"):
    h.check(
        f"anonymous list of {collection} returns no rows",
        h.reads_nothing(collection),
        "a 200 with rows in it is the leak — a list is filtered, not refused",
    )

status, _ = h.req("GET", f"/api/collections/users/records/{member['id']}")
h.check("anonymous view of a user is refused outright", status >= 400, f"status {status}")


# ── Property 2: a role-less account sees nothing ────────────────────────────

print("\n[a role-less account is walled off]")
h.check("...but it can still sign in", roleless_token is not None)
for collection in ("users", "organisations"):
    status, body = h.req("GET", f"/api/collections/{collection}/records", roleless_token)
    h.check(
        f"a role-less account lists no {collection}",
        not (body or {}).get("items"),
        f"status {status}, {len((body or {}).get('items') or [])} items",
    )


# ── Property 3: deactivation ends a LIVE session ────────────────────────────
#
# The reason `is_active` is both the authRule and repeated in every access rule.
# If it only gated sign-in, a deactivated member would keep working until their
# token expired — up to five days.

print("\n[deactivation takes effect immediately]")
victim = h.mk(
    coord_token,
    "users",
    {
        "email": "victim@eiermann.test",
        "password": h.user_pass,
        "passwordConfirm": h.user_pass,
        "org": ORG,
        "role": "member",
        "is_active": True,
    },
)
_, victim_token = h.login("victim@eiermann.test")
h.check("the victim starts out able to read", bool(h.listf(victim_token, "users", "id != ''")))
h.req("PATCH", f"/api/collections/users/records/{victim['id']}", coord_token, {"is_active": False})
status, _ = h.req("POST", "/api/collections/users/auth-refresh", victim_token)
h.check(
    "a deactivated account's EXISTING token stops working",
    status >= 400,
    f"status {status} — if this passes with 200, is_active only gates sign-in "
    f"and a dismissed member keeps access until their token expires",
)
h.check(
    "...and it can no longer read anything",
    not h.listf(victim_token, "users", "id != ''"),
)
status, _ = h.login("victim@eiermann.test")
h.check("...nor sign in again", status >= 400, f"status {status}")


# ── Property 4: the privilege fields are the server's ───────────────────────
#
# The finding this whole hook exists for: `users.updateRule` must let somebody
# edit their own row, and `role` sits on that row. A rule cannot separate them,
# so a hook does. Every case below is an escalation that the access rules alone
# would allow.

print("\n[privilege escalation]")


def role_of(user_id):
    _, body = h.req("GET", f"/api/collections/users/records/{user_id}", coord_token)
    return (body or {}).get("role")


def field_of(user_id, field):
    _, body = h.req("GET", f"/api/collections/users/records/{user_id}", coord_token)
    return (body or {}).get(field)


h.req("PATCH", f"/api/collections/users/records/{member['id']}", member_token, {"role": "coordinator"})
h.check("a member cannot promote themselves", role_of(member["id"]) == "member", str(role_of(member["id"])))

# The version that matters: smuggled alongside a field they ARE allowed to set,
# so the request is otherwise legitimate and the rule's own guard is the only
# thing standing in the way.
h.req(
    "PATCH",
    f"/api/collections/users/records/{member['id']}",
    member_token,
    {"name": "Feldteam", "role": "coordinator"},
)
h.check(
    "...not even smuggled beside a legitimate field",
    role_of(member["id"]) == "member",
    str(role_of(member["id"])),
)

h.req("PATCH", f"/api/collections/users/records/{member['id']}", member_token, {"is_active": False})
h.check("a member cannot deactivate themselves", field_of(member["id"], "is_active") is True)

h.req("PATCH", f"/api/collections/users/records/{member['id']}", member_token, {"verified": True})
h.check("a member cannot self-verify", field_of(member["id"], "verified") is not True)

h.req("PATCH", f"/api/collections/users/records/{coord['id']}", member_token, {"is_active": False})
h.check(
    "a member cannot deactivate the coordinator",
    field_of(coord["id"], "is_active") is True,
)

# Re-tenanting: no legitimate in-app trigger, for anybody.
h.req("PATCH", f"/api/collections/users/records/{member['id']}", member_token, {"org": "org00000other"})
h.check("a member cannot re-tenant themselves", field_of(member["id"], "org") == ORG)
h.req("PATCH", f"/api/collections/users/records/{member['id']}", coord_token, {"org": "org00000other"})
h.check("NOR can a coordinator re-tenant a member", field_of(member["id"], "org") == ORG)

# The lockout: the last coordinator deactivating themselves leaves a team that
# cannot administer itself and cannot be recovered except through the env.
h.req("PATCH", f"/api/collections/users/records/{coord['id']}", coord_token, {"is_active": False})
h.check(
    "a coordinator cannot deactivate THEMSELVES",
    field_of(coord["id"], "is_active") is True,
    "the last coordinator doing this locks the whole team out",
)
h.req("PATCH", f"/api/collections/users/records/{coord['id']}", coord_token, {"role": "member"})
h.check(
    "...nor demote themselves",
    role_of(coord["id"]) == "coordinator",
)


# ── Property 5: what a coordinator legitimately CAN do ──────────────────────
#
# A security test that only asserts refusals is a test that would pass on a
# database nobody can write to at all.

print("\n[the legitimate operations still work]")
status, _ = h.req(
    "PATCH", f"/api/collections/users/records/{member['id']}", member_token, {"name": "Feldteam"}
)
h.check("a member can change their own name", status == 200, f"status {status}")

status, _ = h.req(
    "PATCH", f"/api/collections/users/records/{member['id']}", coord_token, {"role": "coordinator"}
)
h.check("a coordinator can promote a member", role_of(member["id"]) == "coordinator", f"status {status}")
h.req("PATCH", f"/api/collections/users/records/{member['id']}", coord_token, {"role": "member"})

h.check(
    "a member can read the whole team (a visit's author must resolve)",
    len(h.listf(member_token, "users", "id != ''")) >= 2,
)
h.check(
    "a member can read their own organisation",
    len(h.listf(member_token, "organisations", "id != ''")) == 1,
)


# ── Property 6: only the coordination adds people ───────────────────────────

print("\n[who may add and remove people]")
status, _ = h.req(
    "POST",
    "/api/collections/users/records",
    member_token,
    {
        "email": "sneaky@eiermann.test",
        "password": h.user_pass,
        "passwordConfirm": h.user_pass,
        "org": ORG,
        "role": "member",
    },
)
h.check("a member cannot create a user", status >= 400, f"status {status}")

status, _ = h.req("DELETE", f"/api/collections/users/records/{member['id']}", coord_token)
h.check(
    "NOBODY deletes a user, not even the coordination",
    status >= 400,
    "a departed member's name still has to appear on the visits they recorded",
)

status, _ = h.req(
    "PATCH", f"/api/collections/organisations/records/{ORG}", coord_token, {"name": "pwned"}
)
h.check(
    "not even a coordinator writes the organisation through the API",
    status >= 400,
    "the settings JSON has one reader; changing it is an operator act",
)


# ── Property 7: the infrastructure tables are opaque ────────────────────────

print("\n[infrastructure is not domain data]")
for collection in ("geocode_cache", "idempotency_keys"):
    for name, token in (("a member", member_token), ("a coordinator", coord_token)):
        status, body = h.req("GET", f"/api/collections/{collection}/records", token)
        h.check(
            f"{name} cannot read {collection}",
            status >= 400 or not (body or {}).get("items"),
            f"status {status}",
        )


# ── Spots: the centre of the product ───────────────────────────────────────
#
# Every member walks the shared route, so everything in the org is readable by
# everybody in it — a Spot only one person can see is a Spot that gets visited
# twice or not at all. What is NOT shared is the destructive route: deleting a
# Spot destroys its whole dossier, and that stays the coordination's.

print("\n[spots]")

spot = h.mk(
    member_token,
    "spots",
    {
        "org": ORG,
        "name": "Bahnhofstraße 12",
        "street": "Bahnhofstraße 12",
        "city": "Oldenburg",
        "phase": "active",
        "access_note": "Klingel Hausmeister, Schlüssel im Kasten links",
    },
)
h.check("a member can add a building they walked past", spot.get("id") is not None)

h.check(
    "another member sees it immediately",
    any(s["id"] == spot["id"] for s in h.listf(coord_token, "spots", "id != ''")),
    "a Spot only its author can see is the handover problem, not a fix for it",
)

status, _ = h.req(
    "PATCH", f"/api/collections/spots/records/{spot['id']}", member_token,
    {"access_note": "Neuer Schlüsselkasten rechts"},
)
h.check("any member can correct the access note", status == 200, f"status {status}")

# The rhythm's output is the server's. A client that can write it can make a
# nest look visited without anybody going there — the one lie this data model
# must not be able to tell.
h.req(
    "PATCH", f"/api/collections/spots/records/{spot['id']}", member_token,
    {"next_due_at": "2099-01-01 00:00:00.000Z"},
)
_, after = h.req("GET", f"/api/collections/spots/records/{spot['id']}", coord_token)
h.check(
    "NOBODY can write next_due_at through the API",
    not (after or {}).get("next_due_at"),
    "it is derived; a writable due date is a Spot that can claim to be done",
)

h.req(
    "PATCH", f"/api/collections/spots/records/{spot['id']}", member_token,
    {"org": "org00000other"},
)
_, after = h.req("GET", f"/api/collections/spots/records/{spot['id']}", coord_token)
h.check("a Spot cannot be re-tenanted", (after or {}).get("org") == ORG)

status, _ = h.req("DELETE", f"/api/collections/spots/records/{spot['id']}", member_token)
h.check(
    "a member cannot DELETE a Spot",
    status >= 400,
    "closing keeps the dossier; deleting destroys the Erkundung history, every "
    "visit and every check",
)

h.check(
    "a Spot yields nothing to an anonymous caller",
    h.reads_nothing("spots"),
    "a list is FILTERED, not refused — the leak is a 200 with rows in it",
)

status, body = h.req("GET", "/api/collections/spots/records", roleless_token)
h.check(
    "a role-less account sees no Spots",
    not (body or {}).get("items"),
    f"{len((body or {}).get('items') or [])} items",
)


# ── Contacts: the app's only holding of third-party PII ─────────────────────

print("\n[spot contacts]")

contact = h.mk(
    member_token,
    "spot_contacts",
    {
        "org": ORG,
        "spot": spot["id"],
        "role": "caretaker",
        "name": "Herr Kröger",
        "phone": "0441 123456",
        "is_primary": True,
    },
)
h.check("a member can record a caretaker", contact.get("id") is not None)
h.check(
    "the whole team can read the phone number",
    any(c["id"] == contact["id"] for c in h.listf(coord_token, "spot_contacts", "id != ''")),
    "'ask the coordinator for the number' is the failure this app removes",
)

h.req(
    "PATCH", f"/api/collections/spot_contacts/records/{contact['id']}", member_token,
    {"spot": "someotherspot"},
)
_, after = h.req(
    "GET", f"/api/collections/spot_contacts/records/{contact['id']}", coord_token
)
h.check(
    "a contact cannot be moved to another Spot",
    (after or {}).get("spot") == spot["id"],
    "an update rule resolves `spot` against the STORED record, so a "
    "re-parenting write would be authorised against the old one",
)

h.check(
    "a contact is not readable anonymously",
    h.reads_nothing("spot_contacts", record_id=contact["id"]),
)

status, body = h.req("GET", "/api/collections/spot_contacts/records", roleless_token)
h.check("a role-less account sees no contacts", not (body or {}).get("items"))

# Deleting a Spot takes its contacts with it. That cascade IS the retention
# policy: unlike federfall's finders there is no scrub cron here, because a
# caretaker's number is needed for as long as the Spot exists — and a scrub
# would delete the thing the collection is for.
doomed = h.mk(
    coord_token,
    "spots",
    {"org": ORG, "name": "Wird gelöscht", "phase": "prospect"},
)
doomed_contact = h.mk(
    coord_token,
    "spot_contacts",
    {"org": ORG, "spot": doomed["id"], "role": "owner", "name": "Zum Löschen"},
)
status, _ = h.req("DELETE", f"/api/collections/spots/records/{doomed['id']}", coord_token)
h.check("a coordinator CAN delete a Spot", h.ok(status), f"status {status}")
status, _ = h.req(
    "GET", f"/api/collections/spot_contacts/records/{doomed_contact['id']}", coord_token
)
h.check(
    "...and the cascade takes the PII with it",
    status >= 400,
    "the cascade IS the retention policy here; an orphaned contact would be "
    "personal data nothing is left to expire",
)


# ── The overview view ──────────────────────────────────────────────────────
#
# A view does NOT inherit its source's rules. Forgetting that is how a carefully
# scoped table becomes readable through a view over it, so the scope is asserted
# on the view itself and not assumed from `spots`.

print("\n[spot_overview]")

status, body = h.req("GET", "/api/collections/spot_overview/records", member_token)
h.check("a member reads the overview", status == 200, f"status {status}")
rows = (body or {}).get("items") or []
h.check("...and it has rows", bool(rows))

status, body = h.req("GET", "/api/collections/spot_overview/records")
h.check(
    "the view is NOT readable anonymously",
    status >= 400 or not (body or {}).get("items"),
    "a view does not inherit the rules of the table under it",
)

status, body = h.req("GET", "/api/collections/spot_overview/records", roleless_token)
h.check("a role-less account sees no overview rows", not (body or {}).get("items"))

status, _ = h.req(
    "POST", "/api/collections/spot_overview/records", coord_token,
    {"org": ORG, "name": "nope"},
)
h.check(
    "the view is not writable, by anybody",
    status >= 400,
    f"status {status}",
)

# The urgency ladder is what the map colours by, so its ordering is a contract.
active_spot = h.mk(
    coord_token,
    "spots",
    {"org": ORG, "name": "Überfällig", "phase": "active"},
)
h.req(
    "PATCH", f"/api/collections/spots/records/{active_spot['id']}", T,
    {"next_due_at": h.stamp(days=-3)},
)
prospect = h.mk(
    coord_token, "spots", {"org": ORG, "name": "Erkundung", "phase": "prospect"}
)
closed = h.mk(
    coord_token,
    "spots",
    {"org": ORG, "name": "Vernetzt", "phase": "closed", "closed_reason": "netted"},
)


def urgency_of(spot_id):
    _, body = h.req(
        "GET", f"/api/collections/spot_overview/records/{spot_id}", member_token
    )
    raw = (body or {}).get("urgency")
    # A computed view column comes back typed as json, so this may be a
    # string-encoded number. Reading it with int() straight would work today and
    # break the day PocketBase changes its inference.
    return int(str(raw).strip('"')) if raw is not None else None


h.check("an overdue Spot ranks most urgent", urgency_of(active_spot["id"]) == 0)
h.check("a prospect ranks below every active Spot", urgency_of(prospect["id"]) == 4)
h.check("a closed Spot ranks last", urgency_of(closed["id"]) == 6)

no_date = h.mk(
    coord_token, "spots", {"org": ORG, "name": "Neu, noch kein Nest", "phase": "active"}
)
h.check(
    "an active Spot with NO due date is not treated as overdue",
    urgency_of(no_date["id"]) == 3,
    "it is waiting for its first nest, not overdue — painting every new "
    "building red is how a colour stops being read",
)

_, body = h.req(
    "GET",
    "/api/collections/spot_overview/records?sort=urgency&perPage=100",
    member_token,
)
ranks = [int(str(i.get("urgency")).strip('"')) for i in (body or {}).get("items") or []]
h.check("the view can be SORTED by urgency", ranks == sorted(ranks), str(ranks))

_, body = h.req(
    "GET", f"/api/collections/spot_overview/records/{spot['id']}", member_token
)
count = (body or {}).get("contact_count")
h.check(
    "the overview counts contacts, so a list row costs no extra query",
    int(str(count).strip('"')) == 1,
    f"contact_count={count!r}",
)


# ── Custom routes ──────────────────────────────────────────────────────────
#
# The rule suite covers collections; these routes are the part of the API that
# no access rule describes, and until this section existed nothing called them
# at all. The geocode proxy shipped broken for exactly that reason.

print("\n[custom routes]")

import os

HOOKS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pb_hooks")
offenders = h.hook_scope_offenders(HOOKS)
h.check(
    "no hook declares a binding at file level",
    not offenders,
    "each handler runs in its own JSVM context, so these are NOT in scope "
    f"inside it — a 400 at request time: {offenders}",
)

status, body = h.req("GET", "/api/eiermann/info")
h.check("/info is readable anonymously", status == 200, f"status {status}")
h.check(
    "...and names the service, so a client can refuse the wrong server",
    (body or {}).get("service") == "eiermann",
    f"service={(body or {}).get('service')!r}",
)

status, _ = h.req("GET", "/api/eiermann/geocode?q=Oldenburg")
h.check(
    "the geocode proxy refuses an anonymous caller",
    status == 401,
    f"status {status} — an open proxy burns somebody else's upstream budget",
)

# This suite deliberately CANNOT reach a real geocoder: run.sh points
# EIERMANN_NOMINATIM_URL at a closed port. That is not a limitation to work
# around, it is what makes the next two assertions mean anything — a refused
# connection separates "the input was rejected" (400) from "the input was
# accepted and the upstream then failed" (502). Without that separation a
# coordinate-validation test passes on a route that rejects everything.
#
# The live path is exercised against the dev stack, which does reach Nominatim.

status, body = h.req(
    "GET", "/api/eiermann/geocode?q=Bahnhofstra%C3%9Fe%2012%2C%20Oldenburg",
    member_token,
)
h.check(
    "a well-formed query reaches the upstream and fails as a 502",
    status == 502,
    f"status {status}, {str(body)[:120]} — an uncaught throw here would be a "
    "400, which tells the client its address was malformed when it was fine",
)

status, body = h.req(
    "GET", "/api/eiermann/geocode/reverse?lat=53.1435&lon=8.2146", member_token
)
h.check(
    "valid coordinates likewise get past validation to a 502",
    status == 502,
    f"status {status}, {str(body)[:120]}",
)

status, _ = h.req("GET", "/api/eiermann/geocode", member_token)
h.check(
    "a query-less geocode call is a 400, not a 500",
    status == 400,
    f"status {status}",
)

status, _ = h.req(
    "GET", "/api/eiermann/geocode/reverse?lat=notanumber&lon=8.2", member_token
)
h.check(
    "a non-numeric coordinate is rejected",
    status == 400,
    f"status {status} — it would otherwise reach the upstream URL as text",
)

h.check(
    "the geocode cache is not client-readable",
    h.reads_nothing("geocode_cache", member_token),
    "it holds every address anybody has searched for",
)


# ── Sweeps: the properties that must hold for collections not written yet ───

print("\n[sweeps over the live schema]")
cols = h.collections(T)
h.check("the schema lists collections at all", bool(cols))

# users and organisations have their own bespoke rules asserted above;
# the two infrastructure tables are deliberately opaque. Everything ELSE has to
# satisfy the sweeps — including collections nobody has written yet, which is
# the entire point of expressing these as sweeps.
DOMAIN_EXEMPT = {"users", "organisations", "geocode_cache", "idempotency_keys"}


def every_rule_is_gated(col):
    """No rule may be reachable without an authenticated, active, role-bearing
    caller. A rule that omits one of those three is the whole security model
    quietly not applying to one collection."""
    if col["name"] in DOMAIN_EXEMPT:
        return ""
    problems = []
    for kind in ("listRule", "viewRule", "createRule", "updateRule", "deleteRule"):
        rule = col.get(kind)
        if rule is None:
            continue  # superuser-only, the strongest statement available
        if '@request.auth.id != ""' not in rule:
            problems.append(f"{kind} has no auth check")
        if "@request.auth.is_active = true" not in rule:
            problems.append(f"{kind} has no is_active check")
    return "; ".join(problems)


sweep_collections(
    h,
    cols,
    "every domain rule requires an authenticated, active caller",
    every_rule_is_gated,
)


def org_scoped(col):
    """Every client-writable domain collection carries an `org`, because that is
    what every rule compares against. One without it has nothing to scope."""
    if col["name"] in DOMAIN_EXEMPT:
        return ""
    names = [f.get("name") for f in fields_of(col)]
    return "" if "org" in names else "no org field"


sweep_collections(h, cols, "every domain collection is org-scoped", org_scoped)


def org_is_pinned(col):
    """A rule that scopes by `org` must also forbid CHANGING it. An update rule
    resolves field references against the STORED record, so without the guard the
    write is authorised against the old org and lands in the new one."""
    if col["name"] in DOMAIN_EXEMPT:
        return ""
    rule = col.get("updateRule")
    if not rule or "org = @request.auth.org" not in rule:
        return ""
    return "; ".join(missing_isset_guards(rule, ["org"]))


sweep_collections(h, cols, "every org-scoped update rule pins org", org_is_pinned)

print(
    f"\n({len(base_collections(cols))} client-writable base collections swept; "
    f"the sweeps carry the properties forward to collections that do not exist yet)"
)

sys.exit(h.summary())
