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
    status, body = h.req("GET", f"/api/collections/{collection}/records")
    items = (body or {}).get("items")
    h.check(
        f"anonymous list of {collection} returns no rows",
        status >= 400 or not items,
        f"status {status}, {len(items or [])} items — a 200 with rows is the leak",
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


# ── Sweeps: the properties that must hold for collections not written yet ───

print("\n[sweeps over the live schema]")
cols = h.collections(T)
h.check("the schema lists collections at all", bool(cols))

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
