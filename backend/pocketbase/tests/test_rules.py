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
import urllib.parse

import zv_shared_assertions as shared_assertions
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

# The `guest` role (migration 014): where a self-registered OAuth2 account lands
# when the identity provider asserted no group this app maps. Authenticated, and
# behind the wall — which since 014 is a NAMED role rather than the absence of
# one, because `zv_oauth2_provisioning.js` has to be able to write it.
guest = h.mk(
    coord_token,
    "users",
    {
        "email": "guest@eiermann.test",
        "password": h.user_pass,
        "passwordConfirm": h.user_pass,
        "org": ORG,
        "role": "guest",
        "is_active": True,
    },
)
_, guest_token = h.login("guest@eiermann.test")


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


# ── Property 2b: a GUEST sees nothing either ────────────────────────────────
#
print("\n[the guest wall]")
h.check(
    "a guest can sign in",
    guest_token is not None,
    "it has to be able to reach the screen that says it is waiting for access — "
    "an account that cannot authenticate cannot be told anything",
)
h.check(
    "...and is stored as a guest",
    guest.get("role") == "guest",
    str(guest.get("role")),
)

status, _ = h.req(
    "POST", "/api/collections/spots/records", guest_token,
    {"org": ORG, "name": "Vom Fremden", "phase": "prospect"},
)
h.check("a guest cannot create a Spot", status >= 400, f"status {status}")


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

# ── An invited account is REACHABLE by the team that invited it ────────────
#
# `emailVisibility` defaults to false, and PocketBase then omits `email` from
# every response except the record's own owner and a superuser. So the roster —
# which `users.listRule` deliberately opens to the whole team — would render a
# column of blanks, and the pending screen's "you signed in under a different
# address than the one you were invited under" would have nothing to compare
# against.
#
# The hook sets it for every coordinator-created account rather than trusting
# the body, so it holds for a client that never heard of the flag.
invited = h.mk(
    coord_token,
    "users",
    {
        "email": "invited@eiermann.test",
        "password": h.user_pass,
        "passwordConfirm": h.user_pass,
        "org": ORG,
        "role": "member",
        "name": "Eingeladen",
    },
)
h.check(
    "a coordinator-created account is email-visible to its team",
    invited.get("emailVisibility") is True,
    str(invited.get("emailVisibility")),
)
_, seen = h.req("GET", f"/api/collections/users/records/{invited['id']}", member_token)
h.check(
    "...so a COLLEAGUE actually reads the address, not a blank",
    (seen or {}).get("email") == "invited@eiermann.test",
    f"got {(seen or {}).get('email')!r} — a roster of blank addresses is a "
    f"roster nobody can act on",
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


def refusal_codes(body):
    """The refusal codes in an error body.

    A hook refuses with a CODE, never with a sentence: the server does not know
    which language the reader speaks. The code travels as a KEY of `data`,
    because that is the only part PocketBase leaves alone — it rewrites every
    value to {code: "validation_invalid_value", ...} and even capitalises and
    full-stops `message`.
    """
    return sorted((body or {}).get("data") or {})


def refused_with(body, code):
    return code in refusal_codes(body)


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
_, before = h.req(
    "GET", f"/api/collections/spots/records/{spot['id']}", coord_token
)
h.req(
    "PATCH", f"/api/collections/spots/records/{spot['id']}", member_token,
    {"next_due_at": "2099-01-01 00:00:00.000Z"},
)
_, after = h.req("GET", f"/api/collections/spots/records/{spot['id']}", coord_token)
h.check(
    "NOBODY can write next_due_at through the API",
    (after or {}).get("next_due_at") == (before or {}).get("next_due_at"),
    f"{(before or {}).get('next_due_at')!r} → "
    f"{(after or {}).get('next_due_at')!r} — it is derived; a writable due date "
    "is a Spot that can claim to be done",
)
h.check(
    "...and the value it kept is the DERIVED one, not nothing",
    "2099" not in str((after or {}).get("next_due_at") or ""),
    "an assertion that the field is merely EMPTY would pass on a server that "
    "had stopped deriving it at all",
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

# A brand-new active Spot with no nest yet. It is DUE — the base period from
# the day it was added — and on that day it ranks 3, not 2.
#
# eiermann-uga: rank 2 is what this asserted before, and that was an ARTIFACT
# rather than a decision. The window was a fixed `+7 days` and the base period
# is 7 days, so day one landed inside it — as did every day of every rhythm,
# which is exactly what made the rank say nothing. With the window a quarter of
# the interval, a Spot a full period out is in rhythm, climbs to rank 2 five
# days later, then 1, then 0. It still surfaces inside its first period, and the
# dossier says why in words (`dueExplainNoNests`).
#
# What this does NOT settle: whether "no nest recorded yet" deserves a signal of
# its own instead of borrowing a due rank. It probably does, and it is filed
# separately — a building nobody has been to is a different kind of work from a
# nest falling due, and the ladder cannot say so.
#
# The view's rank-3 branch for an active Spot with an EMPTY next_due_at is still
# not asserted here, because the create hook derives the date and the branch can
# no longer be reached through the API. It stays in the view as the defensive
# answer for a row that somehow has no date: reading a missing date as urgent
# would be worse. Hence the date assertion below — without it this check would
# also pass on a Spot that got no date at all.
fresh_active = h.mk(
    coord_token, "spots", {"org": ORG, "name": "Neu, noch kein Nest", "phase": "active"}
)
_, fresh_row = h.req(
    "GET", f"/api/collections/spot_overview/records/{fresh_active['id']}", member_token
)
h.check(
    "a Spot created active gets a date in the future, not none and not the past",
    (fresh_row or {}).get("next_due_at", "")[:10] > h.stamp()[:10],
    f"next_due_at {(fresh_row or {}).get('next_due_at')!r}",
)
h.check(
    "a Spot created active is in rhythm on day one, not already due-soon",
    urgency_of(fresh_active["id"]) == 3,
    f"urgency {urgency_of(fresh_active['id'])} — a full base period out is not "
    '"soon"; a window as wide as the period is what made rank 2 permanent',
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


# ── The Spot lifecycle ─────────────────────────────────────────────────────
#
# Enforced by a hook, not a rule, and the reason is worth restating: a plain
# field reference in an UPDATE rule resolves against the STORED record, so a
# rule can see the phase a Spot is LEAVING but not the one it is entering. A
# transition is a statement about both.

print("\n[spot lifecycle]")


def phase_of(spot_id):
    _, body = h.req("GET", f"/api/collections/spots/records/{spot_id}", coord_token)
    return (body or {}).get("phase")


def move(spot_id, token=None, **fields):
    return h.req(
        "PATCH", f"/api/collections/spots/records/{spot_id}",
        token or member_token, fields,
    )


funnel = h.mk(
    member_token,
    "spots",
    {"org": ORG, "name": "Erkundung läuft", "phase": "prospect",
     "prospect_stage": "untouched"},
)

status, body = move(funnel["id"], phase="active")
h.check(
    "a prospect cannot go active before the Erkundung reaches a yes",
    status == 400,
    f"status {status} — entering a building nobody agreed to is the one legal "
    "risk in the product, so it is gated on the data and not on somebody "
    "remembering to check",
)
h.check(
    "...and says WHICH rule refused, as a code",
    refused_with(body, "spot_phase_needs_permitted"),
    f"{refusal_codes(body)} — the client holds the ARB and the record it just "
    "tried to write; the one thing it cannot know is which invariant said no",
)
message = str((body or {}).get("message") or "")
h.check(
    "...and the message is a developer line, not copy",
    message.isascii(),
    f"{message!r} — German here would be untranslatable by construction, and "
    "PocketBase rewrites this field anyway: it capitalises it and appends a "
    "full stop, so it cannot even carry an exact token",
)

status, _ = move(funnel["id"], prospect_stage="tenant_spoken")
h.check("the funnel itself advances freely", h.ok(status), f"status {status}")
status, _ = move(funnel["id"], prospect_stage="permitted")
h.check("...up to a yes", h.ok(status), f"status {status}")

status, _ = move(funnel["id"], phase="active")
h.check("with the yes recorded, it goes active", h.ok(status), f"status {status}")
_, body = h.req(
    "GET", f"/api/collections/spots/records/{funnel['id']}", coord_token
)
h.check(
    "and prospect_stage SURVIVES going active",
    (body or {}).get("prospect_stage") == "permitted",
    "how permission was obtained is part of the dossier — losing it is how the "
    "same conversation gets had twice",
)

status, _ = move(funnel["id"], phase="prospect")
h.check(
    "an active Spot cannot go back to Erkundung",
    status == 400,
    f"status {status} — permission is not un-learned; losing it is a close "
    "with permission_withdrawn, which keeps the history",
)

# Pausing.
status, body = move(funnel["id"], phase="paused")
h.check(
    "a pause without a reason is refused",
    status == 400,
    f"status {status} — a Spot that went quiet without saying why is "
    "indistinguishable from a forgotten one",
)

status, _ = move(
    funnel["id"], phase="paused", pause_reason="Gerüst bis Ende Oktober",
    paused_until="2026-10-31 00:00:00.000Z",
)
h.check("a pause with a reason is accepted", h.ok(status), f"status {status}")
h.check("...and the Spot is paused", phase_of(funnel["id"]) == "paused")

status, _ = move(funnel["id"], phase="active")
h.check("resuming needs nothing extra", h.ok(status), f"status {status}")
_, body = h.req(
    "GET", f"/api/collections/spots/records/{funnel['id']}", coord_token
)
h.check(
    "resuming CLEARS the pause reason and date",
    not (body or {}).get("pause_reason") and not (body or {}).get("paused_until"),
    f"pause_reason={(body or {}).get('pause_reason')!r} — these are current "
    "state, not history: a resumed Spot still showing 'wegen Gerüst' reads as "
    "still paused",
)

status, _ = move(funnel["id"], phase="prospect", prospect_stage="untouched")
h.check("a paused-then-active Spot still cannot rewind", status == 400)

# Closing.
status, body = move(funnel["id"], phase="closed")
h.check(
    "closing without a reason is refused",
    status == 400,
    f"status {status} — 'closed' alone cannot answer the only question anybody "
    "asks of a closed Spot: do we try again?",
)

status, _ = move(funnel["id"], phase="closed", closed_reason="netted")
h.check("closing with a reason is accepted", h.ok(status), f"status {status}")
_, body = h.req(
    "GET", f"/api/collections/spots/records/{funnel['id']}", coord_token
)
h.check(
    "the server stamps closed_at",
    bool((body or {}).get("closed_at")),
    "derived like next_due_at: a client that can write it can backdate a "
    "decision nobody made",
)

status, _ = move(funnel["id"], phase="paused", pause_reason="egal")
h.check(
    "a closed Spot cannot be paused",
    status == 400,
    f"status {status} — reopening means somebody is going back, so it lands in "
    "aktiv; 'closed, then paused' is a state nobody can act on",
)

status, _ = move(funnel["id"], phase="active")
h.check("a closed Spot CAN be reopened", h.ok(status), f"status {status}")
_, body = h.req(
    "GET", f"/api/collections/spots/records/{funnel['id']}", coord_token
)
h.check(
    "reopening clears the closing reason and date",
    not (body or {}).get("closed_reason") and not (body or {}).get("closed_at"),
    f"closed_reason={(body or {}).get('closed_reason')!r}",
)

# A refused Erkundung is the one close that needs no closed_reason: the refusal
# is already recorded in the field built for it, and none of the closed_reason
# values ("netted", "permission_withdrawn", "building_gone", "no_pigeons")
# describes an owner who simply said no.
refused = h.mk(
    member_token,
    "spots",
    {"org": ORG, "name": "Absage", "phase": "prospect", "prospect_stage": "refused"},
)
status, _ = move(refused["id"], phase="closed")
h.check(
    "a REFUSED prospect closes without a closed_reason",
    h.ok(status),
    f"status {status} — the refusal is the reason, in the field that holds it",
)

# ...and once closed, it can still be WORKED ON. The reason check belongs to the
# transition, not to every later write: a Spot closed from a refused Erkundung
# carries no closed_reason by design, so re-checking it on each update refused
# every subsequent write — a note, a corrected name, anything. Measured as a 400
# on a PATCH that only touched `note`.
status, _ = move(refused["id"], note="Nachbar sagt, neuer Eigentümer ab Frühjahr")
h.check(
    "a Spot closed after a refusal can still be edited",
    h.ok(status),
    f"status {status} — otherwise the one closing that needs no reason is also "
    "the one nobody can ever touch again",
)
status, _ = move(refused["id"], closed_reason="")
h.check(
    "...and an explicit empty reason is still fine on it",
    h.ok(status),
    f"status {status} — the refusal in prospect_stage IS the reason",
)

status, _ = move(
    h.mk(member_token, "spots",
         {"org": ORG, "name": "Unberührte Absage", "phase": "prospect"})["id"],
    phase="closed",
)
h.check(
    "...but an untouched prospect still needs one",
    status == 400,
    f"status {status} — otherwise every abandoned Erkundung closes silently",
)

# Creating is not a transition: a group with a long-standing arrangement should
# not have to invent a prospect phase it never went through.
direct = h.mk(
    member_token,
    "spots",
    {"org": ORG, "name": "Seit Jahren Zugang", "phase": "active"},
)
h.check(
    "a Spot can be CREATED active, with no funnel behind it",
    direct.get("phase") == "active",
    "inventing an Erkundung that never happened would be a false history",
)

status, _ = h.req(
    "POST", "/api/collections/spots/records", member_token,
    {"org": ORG, "name": "Direkt zu", "phase": "closed"},
)
h.check(
    "but creating a closed Spot still needs a reason",
    status == 400,
    f"status {status}",
)

status, _ = h.req(
    "POST", "/api/collections/spots/records", member_token,
    {"org": ORG, "name": "Quatschphase", "phase": "verschimmelt"},
)
h.check("an unknown phase is rejected", status == 400, f"status {status}")

# The phase decides whether a Spot has a due date AT ALL, so every transition
# has to re-derive it. Nothing else in this collection can move the date, and
# nothing but the rhythm library computes it: the hook calls the same
# recomputeSpotDue the visit endpoint does.
#
# Left alone, both directions state something false. A paused Spot keeps the
# date it had and its row reads "Pausiert · fällig am 3. August"; a Spot
# activated out of an Erkundung has no date at all and sits in the list as "Im
# Rhythmus" with nothing behind it.


def due_of(spot_id):
    _, body = h.req("GET", f"/api/collections/spots/records/{spot_id}", coord_token)
    return str((body or {}).get("next_due_at") or "")


fresh = h.mk(
    member_token,
    "spots",
    {"org": ORG, "name": "Sofort fällig", "phase": "active"},
)
h.check(
    "a Spot CREATED active is due from its first second",
    bool(fresh.get("next_due_at")),
    "a building with no nests recorded is a building nobody has looked at "
    "properly — the one thing it must not do is drop out of the list",
)
h.check(
    "...and the CREATE RESPONSE already says so",
    str(fresh.get("next_due_at") or "") == due_of(fresh["id"]),
    f"body {fresh.get('next_due_at')!r} vs row {due_of(fresh['id'])!r} — the "
    "date has to be set BEFORE the write: a record mutated after e.next() never "
    "reaches the reply, so the client would be told the value it just replaced",
)

seeded = h.mk(
    member_token,
    "spots",
    {"org": ORG, "name": "Erst reden", "phase": "prospect"},
)
h.check(
    "a Spot created as an Erkundung is not due at all",
    not seeded.get("next_due_at"),
    "it needs a conversation, not a visit",
)

status, body = move(fresh["id"], phase="paused", pause_reason="Gerüst")
h.check("pausing succeeds", h.ok(status), f"status {status}")
h.check(
    "...and CLEARS the due date",
    not due_of(fresh["id"]),
    "a paused Spot drops out of every due list — a stale date next to "
    "'Pausiert' is two statements that cannot both be true",
)
h.check(
    "...in the response body too",
    not (body or {}).get("next_due_at"),
    f"body next_due_at={(body or {}).get('next_due_at')!r}",
)

status, _ = move(fresh["id"], phase="active")
h.check("resuming succeeds", h.ok(status), f"status {status}")
h.check(
    "...and gives the date back",
    bool(due_of(fresh["id"])),
    "coming back from a pause means coming back into the rhythm",
)

status, _ = move(fresh["id"], phase="closed", closed_reason="netted")
h.check("closing succeeds", h.ok(status), f"status {status}")
h.check(
    "...and clears the due date as well",
    not due_of(fresh["id"]),
    "a closed Spot is not due; it stays on the map, visually distinct",
)

before = due_of(seeded["id"])
status, _ = move(seeded["id"], name="Erst reden, dann rein")
h.check("renaming a Spot succeeds", h.ok(status), f"status {status}")
h.check(
    "an edit that does NOT move the phase leaves the date alone",
    due_of(seeded["id"]) == before,
    f"{before!r} → {due_of(seeded['id'])!r} — re-deriving on every write would "
    "put a second save behind every form",
)


# ── Areas and nests ────────────────────────────────────────────────────────

print("\n[areas and nests]")

host = h.mk(
    coord_token,
    "spots",
    {"org": ORG, "name": "Dachstuhl-Haus", "phase": "active"},
)
area = h.mk(
    member_token,
    "areas",
    {"org": ORG, "spot": host["id"], "name": "Dachboden Nord", "sort_index": 1},
)
h.check("a member can add a Bereich", area.get("id") is not None)

h.req(
    "PATCH", f"/api/collections/areas/records/{area['id']}", member_token,
    {"spot": "someotherspot"},
)
_, after = h.req("GET", f"/api/collections/areas/records/{area['id']}", coord_token)
h.check(
    "a Bereich cannot be moved to another building",
    (after or {}).get("spot") == host["id"],
    "it would take its nests, and their whole check history, with it",
)

status, _ = h.req("DELETE", f"/api/collections/areas/records/{area['id']}", member_token)
h.check("a member cannot delete a Bereich", status >= 400, f"status {status}")

nest = h.mk(
    member_token,
    "nests",
    {"org": ORG, "area": area["id"], "label": "N1", "species": "unknown",
     "status": "active", "pin_x": 0.42, "pin_y": 0.31},
)
h.check("a member can add a nest", nest.get("id") is not None)
h.check(
    "the server derives `spot` from the Bereich",
    nest.get("spot") == host["id"],
    f"spot={nest.get('spot')!r} — a nest whose spot disagreed with its area "
    "would show on one building's map and in another's due list",
)

# Pins are clamped, not rejected. A pin dropped on the edge of a photo routinely
# computes to just over 1, and roof nests ARE at the edge.
edge = h.mk(
    member_token,
    "nests",
    {"org": ORG, "area": area["id"], "label": "N2", "species": "unknown",
     "status": "active", "pin_x": 1.0000000002, "pin_y": -0.0000001},
)
h.check(
    "a pin just outside 0…1 is accepted, not refused",
    edge.get("id") is not None,
)
h.check(
    "...to exactly the edge",
    float(edge.get("pin_x")) == 1.0 and float(edge.get("pin_y")) == 0.0,
    f"pin_x={edge.get('pin_x')!r} pin_y={edge.get('pin_y')!r}",
)

far = h.mk(
    member_token,
    "nests",
    {"org": ORG, "area": area["id"], "label": "N3", "species": "unknown",
     "status": "active", "pin_x": 1.7, "pin_y": 12},
)
h.check(
    "a wildly out-of-range pin is clamped too",
    float(far.get("pin_x")) == 1.0 and float(far.get("pin_y")) == 1.0,
    f"pin_x={far.get('pin_x')!r} — stored as 1.7 the nest would sit off the "
    "photo forever, invisible on the only screen that shows it",
)

status, _ = h.req(
    "POST", "/api/collections/nests/records", member_token,
    {"org": ORG, "area": area["id"], "label": "N1", "species": "unknown",
     "status": "active"},
)
h.check(
    "a duplicate label in one Bereich is refused",
    status >= 400,
    f"status {status} — 'N3' twice in one attic produces two histories for one "
    "nest, and no screen can show that it happened",
)

status, _ = h.req(
    "PATCH", f"/api/collections/nests/records/{nest['id']}", member_token,
    {"next_due_at": "2099-01-01 00:00:00.000Z", "interval_days": 999,
     "empty_streak": 7},
)
_, after = h.req("GET", f"/api/collections/nests/records/{nest['id']}", coord_token)
h.check(
    "the three rhythm fields are not client-writable",
    not (after or {}).get("next_due_at")
    and not (after or {}).get("interval_days")
    and not (after or {}).get("empty_streak"),
    f"{after and {k: after.get(k) for k in ('next_due_at', 'interval_days', 'empty_streak')}}"
    " — a client that can set these can make a nest look checked without "
    "anybody going there",
)

status, _ = h.req("DELETE", f"/api/collections/nests/records/{nest['id']}", coord_token)
h.check(
    "NOBODY can delete a nest, not even the coordination",
    status >= 400,
    f"status {status} — a nest that disappeared is a FINDING about the "
    "building; `status = gone` records it, deleting would make the history "
    "claim the nest never existed",
)

# The cross-tenant path. This is the one an access rule cannot close: the create
# rule is satisfied by sending your OWN org, and the hook then derives `spot`
# and `org` from the area — so without a check the caller's own org in the body
# plus a foreign area id would move the row into the other organisation.
foreign = h.mk(
    T,
    "organisations",
    {"id": "org00000foreign", "name": "Fremde Gruppe", "is_active": True},
)
foreign_spot = h.mk(
    T, "spots", {"org": "org00000foreign", "name": "Fremdes Haus", "phase": "active"}
)
foreign_area = h.mk(
    T,
    "areas",
    {"org": "org00000foreign", "spot": foreign_spot["id"], "name": "Fremder Dachboden"},
)
status, body = h.req(
    "POST", "/api/collections/nests/records", member_token,
    {"org": ORG, "area": foreign_area["id"], "label": "Einbruch",
     "species": "unknown", "status": "active"},
)
h.check(
    "a nest cannot be hung off ANOTHER org's Bereich",
    status >= 400,
    f"status {status} — the rule passes (the body's org is the caller's own); "
    "only the hook can dereference the area and see whose it is",
)
h.check(
    "...and it is the SAME code as a missing area",
    refused_with(body, "nest_area_not_found"),
    f"{refusal_codes(body)} — a distinct code would tell the caller the id "
    "exists in another organisation, which is exactly what is being hidden",
)

status, body = h.req(
    "GET", f"/api/collections/areas/records/{foreign_area['id']}", member_token
)
h.check("another org's Bereich is not readable", status >= 400, f"status {status}")


# ── The protected-species guard ─────────────────────────────────────────────
#
# City pigeons are feral domestic animals and not specially protected. Jackdaws,
# wood pigeons, swifts and kestrels in the same attics ARE, and interference is
# prohibited under §44 BNatSchG. This is the largest real risk the app can
# AMPLIFY, precisely because it makes clutch swapping fast and routine — so the
# guard exists before the first egg, not after.

print("\n[protected species]")

status, _ = h.req(
    "PATCH", f"/api/collections/nests/records/{nest['id']}", member_token,
    {"species": "protected", "species_label": "Dohle"},
)
h.check(
    "ANY member can mark a nest as protected",
    h.ok(status),
    f"status {status} — the volunteer standing in front of a jackdaw has to be "
    "able to stop the process now, not after finding a coordinator",
)

status, body = h.req(
    "PATCH", f"/api/collections/nests/records/{nest['id']}", member_token,
    {"species": "feral_pigeon"},
)
h.check(
    "a member CANNOT take that back",
    status == 400,
    f"status {status} — releasing it reopens the egg-swap path on a nest "
    "somebody had reason to flag",
)
h.check(
    "...and carries the code the client turns into the §44 explanation",
    refused_with(body, "nest_protected_needs_coordinator"),
    str(refusal_codes(body)),
)
_, after = h.req("GET", f"/api/collections/nests/records/{nest['id']}", coord_token)
h.check("...and the nest is still protected", (after or {}).get("species") == "protected")

status, _ = h.req(
    "PATCH", f"/api/collections/nests/records/{nest['id']}", coord_token,
    {"species": "unknown"},
)
h.check(
    "the coordination CAN release it",
    h.ok(status),
    f"status {status} — the asymmetry is the whole design",
)

status, _ = h.req(
    "PATCH", f"/api/collections/nests/records/{nest['id']}", member_token,
    {"species": "feral_pigeon"},
)
h.check(
    "a member can still classify a nest that was never protected",
    h.ok(status),
    f"status {status} — the guard is about leaving `protected`, not about "
    "species being a coordinator field",
)

# `unknown` is a real state and never a silent "probably a pigeon".
undetermined = h.mk(
    member_token,
    "nests",
    {"org": ORG, "area": area["id"], "label": "N4", "species": "unknown",
     "status": "active"},
)
h.check(
    "a nest can stay undetermined",
    undetermined.get("species") == "unknown",
    "the app does not identify species; an undetermined nest is an open "
    "question in the Spot detail, not an assumption",
)

status, _ = h.req(
    "POST", "/api/collections/nests/records", member_token,
    {"org": ORG, "area": area["id"], "label": "N5", "species": "taube",
     "status": "active"},
)
h.check("an unknown species value is refused", status >= 400, f"status {status}")


# ── The photo-replacement review pass (eiermann-bmg.5) ──────────────────────
#
# A pin is a normalised coordinate ON A PHOTO. Replace the photo and every pin
# still holds the same two numbers while they point somewhere else in the
# building: nothing in the data is wrong and every pin is a lie. Nobody notices
# until somebody stands in an attic looking at the wrong rafter.
#
# So a replacement is a state the Bereich announces — the outgoing photo copied
# to `previous_photo`, `pins_need_review` up — and the review state is the
# server's on every path. These assertions are what makes it not a convention.

print("\n[Bereichsfoto: der Prüfdurchlauf]")

# A real PNG, because PocketBase sniffs the CONTENT against the field's
# mimeTypes: a text blob named .png is refused and every assertion below would
# then pass over an upload that never happened.
import base64

PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/"
    "q842iQAAAABJRU5ErkJggg=="
)


def put_photo(area_id, token=None):
    """Uploads a photo to [area_id]. (status, record)."""
    return h.upload_file(
        "PATCH", f"/api/collections/areas/records/{area_id}", token or member_token,
        "photo", "bereich.png", "image/png", PNG,
    )


def area_now(area_id):
    _, row = h.req(
        "GET", f"/api/collections/areas/records/{area_id}", coord_token
    )
    return row or {}


swap_host = h.mk(
    coord_token, "spots", {"org": ORG, "name": "Fotohaus", "phase": "active"}
)
swap = h.mk(
    member_token,
    "areas",
    {"org": ORG, "spot": swap_host["id"], "name": "Lichtschacht"},
)
h.mk(
    member_token,
    "nests",
    {"org": ORG, "area": swap["id"], "label": "N1", "species": "unknown",
     "status": "active", "pin_x": 0.4, "pin_y": 0.6},
)

status, first = put_photo(swap["id"])
h.check("a Bereich photo uploads", h.ok(status), f"status {status}")
h.check(
    "the FIRST photo starts no review pass",
    not (first or {}).get("pins_need_review")
    and not (first or {}).get("previous_photo"),
    f"{ {k: (first or {}).get(k) for k in ('pins_need_review', 'previous_photo')} }"
    " — nothing was ever placed against an earlier image, so nothing can have "
    "drifted; a flag here would demand a pass over a Bereich nobody changed",
)
original_photo = (first or {}).get("photo")

status, second = put_photo(swap["id"])
h.check("replacing the photo succeeds", h.ok(status), f"status {status}")
h.check(
    "...and raises the review flag",
    (second or {}).get("pins_need_review") is True,
    f"pins_need_review={(second or {}).get('pins_need_review')!r} — the pins "
    "kept their coordinates and now point somewhere else in the building",
)
kept = (second or {}).get("previous_photo")
h.check(
    "...and keeps the outgoing photo to compare against",
    bool(kept),
    "without the old picture beside the new one a reviewer is guessing at what "
    "moved",
)
h.check(
    "...under a file key of its own, not the outgoing name",
    kept != original_photo and kept != (second or {}).get("photo"),
    f"previous_photo={kept!r} photo={original_photo!r} — both fields live in "
    "one record directory, so re-using the name would leave two fields on one "
    "blob and PocketBase deletes the file that left `photo` after the save",
)

# THE assertion the shape of this hook exists for: the kept copy is a real file,
# not a name. A dangling `previous_photo` is a review pass with nothing to
# compare against, and it would be discovered by the volunteer, not by us.
_, file_token = h.req("POST", "/api/files/token", member_token)
status, blob, _ = h.req_bytes(
    "GET",
    f"/api/files/areas/{swap['id']}/{kept}?token={(file_token or {}).get('token', '')}",
)
h.check(
    "the kept photo can actually be fetched",
    h.ok(status) and len(blob) > 0,
    f"status {status}, {len(blob)} bytes — a `previous_photo` naming a file "
    "that is gone is worse than none: the pass demands a comparison it cannot "
    "show",
)

status, body = h.req(
    "PATCH", f"/api/collections/areas/records/{swap['id']}", member_token,
    {"previous_photo": ""},
)
h.check(
    "a client cannot drop the outgoing photo",
    status >= 400 and refused_with(body, "area_review_field_not_writable"),
    f"status {status}, {refusal_codes(body)} — that leaves the flag standing "
    "over a comparison the screen can no longer show",
)
h.check(
    "...and it is still there",
    area_now(swap["id"]).get("previous_photo") == kept,
    "a refusal that refuses and writes anyway is the worst of both",
)

status, body = h.upload_file(
    "PATCH", f"/api/collections/areas/records/{swap['id']}", member_token,
    "previous_photo", "geschmuggelt.png", "image/png", PNG,
)
h.check(
    "...nor upload one INTO the field",
    status >= 400 and refused_with(body, "area_review_field_not_writable"),
    f"status {status}, {refusal_codes(body)} — a file field is writable as a "
    "multipart part as well as by name, so the guard reads the request body "
    "rather than a list of JSON keys",
)

status, body = h.req(
    "PATCH", f"/api/collections/areas/records/{swap['id']}", member_token,
    {"pins_need_review": True},
)
h.check(
    "a client cannot RAISE the review flag",
    status >= 400 and refused_with(body, "area_review_field_not_writable"),
    f"status {status}, {refusal_codes(body)} — the flag means 'the pins were "
    "kept across a photo change', and only the hook that copied the photo "
    "knows that happened",
)

status, done = h.req(
    "PATCH", f"/api/collections/areas/records/{swap['id']}", member_token,
    {"pins_need_review": False},
)
h.check(
    "the pass can be finished",
    h.ok(status) and not (done or {}).get("pins_need_review"),
    f"status {status} — the one write a client makes to the review state",
)
h.check(
    "...and the outgoing photo goes with it",
    not (done or {}).get("previous_photo"),
    f"previous_photo={(done or {}).get('previous_photo')!r} — these are "
    "pictures of the inside of somebody's building; once the pins are "
    "confirmed nothing justifies keeping a second one",
)

# A Bereich nobody has pinned has nothing to review, and flagging it would keep
# a picture of somebody's property for the duration of a formality.
bare = h.mk(
    member_token,
    "areas",
    {"org": ORG, "spot": swap_host["id"], "name": "Ohne Nester"},
)
put_photo(bare["id"])
status, replaced = put_photo(bare["id"])
h.check(
    "a Bereich with no pin is not sent through a pass",
    h.ok(status)
    and not (replaced or {}).get("pins_need_review")
    and not (replaced or {}).get("previous_photo"),
    f"{ {k: (replaced or {}).get(k) for k in ('pins_need_review', 'previous_photo')} }"
    " — there is no coordinate that can have drifted, and the pass would be a "
    "formality paid for with a stored photo of a building",
)


# ── Custom routes ──────────────────────────────────────────────────────────
#
# The rule suite covers collections; these routes are the part of the API that
# no access rule describes, and until this section existed nothing called them
# at all. The geocode proxy shipped broken for exactly that reason.

print("\n[custom routes]")

import os

import glob
import re as _re

HOOKS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pb_hooks")
offenders = h.hook_scope_offenders(HOOKS)
h.check(
    "no hook declares a binding at file level",
    not offenders,
    "each handler runs in its own JSVM context, so these are NOT in scope "
    f"inside it — a 400 at request time: {offenders}",
)

# ...and reaches its helpers the one way that works from inside one.
#
# The other half of the same trap (eiermann-934.4). A handler's own context has
# no file-level bindings, so everything it needs arrives through `require` — and
# `require` there resolves against the PROCESS working directory, not against
# the file doing the requiring. `require("./app_rhythm.js")` therefore reads as
# a path relative to wherever PocketBase happens to have been started, which in
# the dev override, in the image and under `migrate up` are three different
# directories. The absolute `${__hooks}/…` template form is the only spelling
# that resolves in all three, and the failure of any other is again a 400 at
# request time with a `ReferenceError` no log line explains.
#
# `${__hooks}` cannot appear in a plain quoted string, so the sweep is exactly
# "a require whose argument is not a backtick template".
bad_requires = []
for path in sorted(glob.glob(os.path.join(HOOKS, "*.js"))):
    name = os.path.basename(path)
    # Vendored from the base image; zugvogel's own suite owns their spelling.
    if name.startswith("zv_"):
        continue
    with open(path, encoding="utf-8") as handle:
        code = "\n".join(
            line
            for line in handle.read().split("\n")
            if not line.strip().startswith("//")
        )
    for match in _re.finditer(r"require\(\s*([^)]*?)\s*\)", code):
        argument = match.group(1)
        if argument.startswith("`") and "${__hooks}/" in argument:
            continue
        bad_requires.append(f"{name}: require({argument})")

h.check(
    "every require uses the absolute ${__hooks} form",
    not bad_requires,
    f"{bad_requires} — a relative require resolves against the PROCESS working "
    "directory, which differs between the image, the dev override and "
    "`migrate up`",
)
require_count = 0
for path in glob.glob(os.path.join(HOOKS, "*.js")):
    if os.path.basename(path).startswith("zv_"):
        continue
    with open(path, encoding="utf-8") as handle:
        require_count += len(_re.findall(r"require\(", handle.read()))
h.check(
    "...and the sweep found requires to check at all",
    require_count >= 10,
    f"{require_count} requires found — a sweep over nothing passes over "
    "anything",
)


# ── One JSON field, one reader ─────────────────────────────────────────────
#
# eiermann-934.2. `record.get(<json field>)` hands JS a `types.JSONRaw` — a BYTE
# ARRAY. Every property access on it is `undefined`, so a reader written the
# obvious way falls silently through to its own default and the setting is inert
# with no error anywhere. federfall had that trap written five times, correct in
# three; two shipped, documented features were dead for every org.
#
# The countermeasure is arithmetic rather than vigilance: keep the number of
# JSON fields at one and the number of readers at one, and there is one place
# left to get it wrong. zv_org.js is that reader, and it lives in the base image
# so both apps share it.
#
# The list is spelled out rather than counted, so that a fourth JSON field
# fails here and its author has to say which of the two kinds it is: a
# SETTINGS field, which something will eventually want to read and which
# therefore belongs inside zv_org.js's one field — or an OPAQUE payload, stored
# whole and handed back whole, never property-accessed in JS. The two
# infrastructure ones are the second kind: `geocode_cache.response` is replayed
# to the client verbatim and `idempotency_keys.response` is a recorded answer.
# Passing a JSONRaw straight back to Go marshals correctly; only property
# access in JS is broken, which is why those two are safe and a third settings
# field would not be.
json_fields = sorted(
    f"{col['name']}.{field['name']}"
    for col in base_collections(h.collections(T), writable_only=False)
    for field in fields_of(col, "json")
)
h.check(
    "the schema holds exactly one settings JSON field, and two opaque ones",
    json_fields
    == [
        "geocode_cache.response",
        "idempotency_keys.response",
        "organisations.settings",
    ],
    f"{json_fields} — a new JSON field is a new place for `record.get()` to "
    "return a byte array whose every property reads `undefined`. If it holds "
    "configuration, put it in organisations.settings, which zv_org.js already "
    "decodes correctly.",
)

# And nothing here decodes it. An eiermann hook that wants a setting requires
# zv_org.js; one that spells out `getString("settings")` has just become the
# second reader.
own_readers = []
settings_callers = 0
for path in sorted(glob.glob(os.path.join(HOOKS, "*.js"))):
    name = os.path.basename(path)
    if name.startswith("zv_"):
        continue
    with open(path, encoding="utf-8") as handle:
        code = "\n".join(
            line
            for line in handle.read().split("\n")
            if not line.strip().startswith("//")
        )
    if _re.search(r'get(String)?\(\s*["\']settings["\']\s*\)', code):
        own_readers.append(name)
    if "zv_org.js" in code:
        settings_callers += 1

h.check(
    "no eiermann hook decodes organisations.settings itself",
    not own_readers,
    f"{own_readers} — go through require(`${{__hooks}}/zv_org.js`).settingsOf, "
    "which is the one place that knows get() returns a byte array and "
    "getString() does not",
)
h.check(
    "...and the sweep found settings readers to check at all",
    settings_callers >= 2,
    f"{settings_callers} callers of zv_org.js — a sweep over nothing passes "
    "over anything",
)


# ── A view column is asked for by type ─────────────────────────────────────
#
# eiermann-934.3. A column PocketBase cannot trace back to a real one — anything
# computed, which is every interesting column in these four views — falls back
# to type `json`. `getString()` then returns the raw JSON text: `"Bahnhofstr. 1"`
# WITH the quotes, `12` as a string that happens to parse. It fails quietly and
# late: an address sorts under `"`, a date does not parse, an enum misses its
# label map, and the CSV's formula guard inspects a quote instead of the `=` it
# exists to catch.
#
# Sniffing per value is not the fix — a Spot named `true` and a street named
# `123` both parse as JSON just fine, and that row comes back a boolean. The
# collection has to be ASKED. app_stats.js's `viewReader` is where that asking
# lives, and this sweep is what stops the next view reader skipping it.
view_names = [c["name"] for c in h.collections(T) if c.get("type") == "view"]

untyped_view_readers = []
view_reader_hits = 0
for path in sorted(glob.glob(os.path.join(HOOKS, "*.js"))):
    name = os.path.basename(path)
    if name.startswith("zv_"):
        continue
    with open(path, encoding="utf-8") as handle:
        code = "\n".join(
            line
            for line in handle.read().split("\n")
            if not line.strip().startswith("//")
        )
    reads = [v for v in view_names if _re.search(rf'Record[sA-Za-z]*By\w*\(\s*["\']{v}["\']', code)]
    if not reads:
        continue
    view_reader_hits += len(reads)
    # Either it builds the typed reader itself (app_stats.js does) or it takes
    # one from the module that has it.
    if "field.type()" not in code and "viewReader" not in code:
        untyped_view_readers.append(f"{name} reads {reads}")

h.check(
    "every hook that reads a view asks the collection for the column type",
    not untyped_view_readers,
    f"{untyped_view_readers} — a computed column is typed `json` and "
    "getString() returns it WITH the quotes; use app_stats.js's viewReader",
)
h.check(
    "...and the sweep found view reads to check at all",
    view_reader_hits >= 1 and len(view_names) >= 4,
    f"{view_reader_hits} reads over {len(view_names)} views — a sweep over "
    "nothing passes over anything",
)

# A hook must never send a sentence a user reads: the server does not know which
# language the reader speaks. The invariant that delivers that is not "the
# message is in English" — it is that EVERY refusal carries a code, which is
# structural and therefore checkable.
#
# I first wrote this as a non-ASCII sweep, on the theory that German prose
# carries an umlaut or an ß. The canary disproved it in one go: "Eine Pause
# braucht einen Grund." is pure ASCII, so the guard passed with the exact
# violation planted in it. A guard that looks strong and is not is worse than
# none.
#
# So: no hook throws an error directly. Everything goes through
# app_refuse.js's `refuse(code, devMessage, status)`, which cannot construct a
# refusal without a code. That is why `refuse` takes a status at all — the
# idempotency-key clash is a 409, and letting it throw its own ApiError would
# mean this sweep needs an exception, and a sweep with an exception is a sweep
# somebody widens.
direct = []
for path in sorted(glob.glob(os.path.join(HOOKS, "*.js"))):
    name = os.path.basename(path)
    # zv_* are vendored from the base image and have their own conventions;
    # app_refuse.js is where the one legitimate throw lives.
    if name.startswith("zv_") or name == "app_refuse.js":
        continue
    with open(path, encoding="utf-8") as handle:
        code = "\n".join(
            line
            for line in handle.read().split("\n")
            if not line.strip().startswith("//")
        )
    for match in _re.finditer(r"throw new (\w*Error)\(", code):
        kind = match.group(1)
        # UnauthorizedError and ForbiddenError are exempt, and for a reason
        # rather than convenience: their STATUS is the whole message. 401 and
        # 403 already map to localized copy in every client, and there is no
        # app invariant to name — "you are not signed in" needs no code.
        if kind in ("UnauthorizedError", "ForbiddenError"):
            continue
        direct.append(f"{name}: throw new {kind}(")

h.check(
    "no hook throws an error directly — every refusal carries a code",
    not direct,
    f"{direct} — use app_refuse.js's refuse(code, devMessage[, status]). A "
    "thrown message is untranslatable by construction: the server does not "
    "know which language the reader speaks.",
)

# ── Der Rhythmus: the numbers, and the door they are changed through ───────
#
# `organisations.updateRule` is null and stays null, so the settings blob has no
# client-facing write at all. These numbers reach it through one route that
# takes five TYPED fields and merges them — which is the whole point: a
# malformed JSON blob does not error, it falls into defaults, and the app then
# works correctly with numbers nobody chose.

print("\n[the rhythm numbers]")

RHYTHM = "/api/eiermann/rhythm"


def rhythm_of(token):
    _, body = h.req("GET", RHYTHM, token)
    return body or {}


status, _ = h.req("GET", RHYTHM)
h.check("the rhythm route is closed to anonymous callers", status >= 400, f"status {status}")

status, _ = h.req("GET", RHYTHM, guest_token)
h.check(
    "...and to a guest",
    status >= 400,
    f"status {status} — a guest satisfies `role != null`, which is exactly why "
    f"the gate names the roles instead",
)

defaults = rhythm_of(member_token)
h.check(
    "a member READS the numbers",
    defaults.get("baseIntervalDays") == 7 and defaults.get("intervalSteps") == [7, 14, 28],
    f"{defaults} — reading is not administration: somebody looking at 'in 14 "
    f"Tagen' needs to know whether that is the base interval or a stretched one",
)
h.check(
    "...including the half-clutch window and the auto-resume flag",
    defaults.get("halfClutchReturnDays") == 4
    and defaults.get("emptyChecksPerStep") == 3
    and defaults.get("pauseAutoResume") is True,
    str(defaults),
)

status, _ = h.req("PATCH", RHYTHM, member_token, {"baseIntervalDays": 10})
h.check("a member cannot WRITE them", status == 403, f"status {status}")
h.check(
    "...and nothing moved",
    rhythm_of(member_token).get("baseIntervalDays") == 7,
)

# Each refusal below is a number that would have produced a plausible-looking
# app doing the wrong thing. `positiveNumber` falls back to its default for
# anything it cannot read, so an accepted-then-ignored value would be shown on
# the settings screen while the ladder used another one.
for label, body, code in (
    ("zero", {"baseIntervalDays": 0}, "rhythm_base_interval_invalid"),
    ("negative", {"baseIntervalDays": -3}, "rhythm_base_interval_invalid"),
    ("fractional", {"baseIntervalDays": 7.5}, "rhythm_base_interval_invalid"),
    ("absurd", {"baseIntervalDays": 4000}, "rhythm_base_interval_invalid"),
    ("not a number", {"baseIntervalDays": "bald"}, "rhythm_base_interval_invalid"),
    ("zero per step", {"emptyChecksPerStep": 0}, "rhythm_empty_checks_per_step_invalid"),
    ("zero return", {"halfClutchReturnDays": 0}, "rhythm_half_clutch_return_invalid"),
    ("an empty ladder", {"intervalSteps": []}, "rhythm_interval_steps_invalid"),
    ("a ladder of junk", {"intervalSteps": [7, "spaeter"]}, "rhythm_interval_steps_invalid"),
    ("a ladder that is not a list", {"intervalSteps": 7}, "rhythm_interval_steps_invalid"),
):
    status, body_out = h.req("PATCH", RHYTHM, coord_token, body)
    h.check(
        f"{label} is refused with {code}",
        status == 400 and code in refusal_codes(body_out),
        f"status {status}, codes {refusal_codes(body_out)}",
    )

status, body_out = h.req("PATCH", RHYTHM, coord_token, {"intervalSteps": [28, 14, 7]})
h.check(
    "a DESCENDING ladder is refused",
    status == 400 and "rhythm_interval_steps_not_ascending" in refusal_codes(body_out),
    f"status {status}, codes {refusal_codes(body_out)} — the interval is supposed to "
    f"stretch the longer a nest has gone unused; a ladder that comes back down "
    f"inverts the thing it exists for",
)

status, body_out = h.req(
    "PATCH", RHYTHM, coord_token, {"baseIntervalDays": 14, "intervalSteps": [7, 14, 28]}
)
h.check(
    "a first rung BELOW the base interval is refused",
    status == 400 and "rhythm_steps_below_base" in refusal_codes(body_out),
    f"status {status}, codes {refusal_codes(body_out)} — an empty nest would then be "
    f"checked more often than a live one, and no screen would say so",
)

h.check(
    "...and after every refusal the stored numbers are untouched",
    rhythm_of(coord_token) == defaults,
    str(rhythm_of(coord_token)),
)

# The legitimate write. A suite that only asserts refusals would pass against a
# route that refuses everything.
status, written = h.req(
    "PATCH",
    RHYTHM,
    coord_token,
    {"baseIntervalDays": 10, "intervalSteps": [10, 20, 40], "pauseAutoResume": False},
)
h.check(
    "a coordinator changes the numbers",
    status == 200 and (written or {}).get("baseIntervalDays") == 10,
    f"status {status}, {written}",
)
h.check(
    "...and the answer is what the RHYTHM will use, read back after the save",
    (written or {}).get("intervalSteps") == [10, 20, 40]
    and (written or {}).get("pauseAutoResume") is False,
    str(written),
)
h.check(
    "...which is what a member reads too",
    rhythm_of(member_token).get("baseIntervalDays") == 10,
)

# PARTIAL, in fact and not just in verb: a client that sends one number must not
# blank the other four by omission. That is the shape of every accidental
# settings wipe.
status, partial = h.req("PATCH", RHYTHM, coord_token, {"halfClutchReturnDays": 5})
h.check(
    "a PATCH of one field leaves the others alone",
    status == 200
    and (partial or {}).get("halfClutchReturnDays") == 5
    and (partial or {}).get("baseIntervalDays") == 10
    and (partial or {}).get("intervalSteps") == [10, 20, 40],
    str(partial),
)

# The blob is MERGED, never replaced: `settings` is shared with whatever else an
# operator put in it, and a route that owns five keys must not delete a sixth it
# has never heard of.
h.req(
    "PATCH",
    f"/api/collections/organisations/records/{ORG}",
    T,
    {"settings": {"base_interval_days": 10, "operator_note": "nicht anfassen"}},
)
# Not `baseIntervalDays` here: with only `base_interval_days` stored, the ladder
# falls back to its default [7, 14, 28], and raising the base past 7 is then
# refused by `rhythm_steps_below_base` — correctly. `halfClutchReturnDays`
# interacts with nothing, which is what makes it the right probe for the MERGE.
status, _ = h.req("PATCH", RHYTHM, coord_token, {"halfClutchReturnDays": 6})
_, org_row = h.req("GET", f"/api/collections/organisations/records/{ORG}", T)
kept = ((org_row or {}).get("settings") or {})
h.check(
    "an inconsistency inherited from the Admin UI does not block an unrelated edit",
    status == 200,
    f"status {status} — the stored ladder [7,14,28] sits below the stored base "
    f"of 10, which an operator's raw JSON put there; refusing a Nachkontrolle "
    f"edit over it would be a dead end on the one screen that can fix it",
)
h.check(
    "a key this route never heard of survives the write",
    kept.get("operator_note") == "nicht anfassen"
    and kept.get("half_clutch_return_days") == 6
    and kept.get("base_interval_days") == 10,
    f"status {status}, {kept} — the settings blob is one field shared with the "
    f"operator, and a route that owns five keys must not delete a sixth",
)

# Back to the documented defaults, so nothing after this section runs against a
# rhythm this section invented.
h.req("PATCH", f"/api/collections/organisations/records/{ORG}", T, {"settings": {}})
h.check(
    "the defaults come back when the blob is emptied",
    rhythm_of(coord_token) == defaults,
    str(rhythm_of(coord_token)),
)


# Every app route states the gate, and states it from ONE place.
#
# A custom route does not inherit an access rule: a `routerAdd` handler sees a
# raw authenticated caller, and whatever the collections say, it has to check for
# itself. Each route here restated the clause by hand — and three of the four
# restated the PRE-014 version, `is_active && role != null`, which `guest`
# satisfies. Measured: a guest account got a 200 and a complete PDF of every
# address the organisation holds, and could write a Besuch.
#
# So the clause lives in app_auth.js and this sweep is what stops the next route
# writing its own. It greps rather than probes because the property has to hold
# for a route nobody has written yet — a per-route probe can only cover the ones
# that exist, which is exactly how the hole above survived a whole phase.
route_files = {}
for path in sorted(glob.glob(os.path.join(HOOKS, "*.pb.js"))):
    name = os.path.basename(path)
    with open(path, encoding="utf-8") as handle:
        route_files[name] = handle.read()

ungated = []
for name, code in route_files.items():
    if "routerAdd(" not in code:
        continue
    # info.pb.js is deliberately unauthenticated — it is what a client reads
    # BEFORE it can sign in, to learn the server's version and capabilities.
    # geocode.pb.js delegates to the shared library and passes it the walled-off
    # role explicitly, which the geocode assertions above cover.
    if name in ("info.pb.js", "geocode.pb.js"):
        continue
    if "requireMember(e)" not in code:
        ungated.append(name)

h.check(
    "every app route takes its gate from app_auth.js",
    not ungated,
    f"{ungated} — a hand-written `role != null` is the pre-014 clause, and "
    "`guest` satisfies it: the wall a self-registered OAuth2 account lands "
    "behind would not apply to a custom route at all",
)
h.check(
    "...and the sweep found routes to check at all",
    sum(1 for code in route_files.values() if "requireMember(e)" in code) >= 3,
    "a sweep over nothing passes over anything",
)

# `CODES.foo` for a code that is not declared evaluates to `undefined`, and
# `{[undefined]: 1}` becomes the key "undefined" — a refusal the client cannot
# translate, arriving as a generic failure with no error anywhere. A typo would
# be invisible, so it is checked.
with open(os.path.join(HOOKS, "app_refuse.js"), encoding="utf-8") as handle:
    declared = set(_re.findall(r"^  (\w+):", handle.read(), _re.M))

used = set()
for path in sorted(glob.glob(os.path.join(HOOKS, "*.js"))):
    if os.path.basename(path) == "app_refuse.js":
        continue
    with open(path, encoding="utf-8") as handle:
        used.update(_re.findall(r"CODES\.(\w+)", handle.read()))

h.check(
    "every code a hook uses is declared in app_refuse.js",
    not (used - declared),
    f"{sorted(used - declared)} — an undeclared code is `undefined`, and "
    '`{[undefined]: 1}` sends the key "undefined": untranslatable, and silent',
)
h.check(
    "...and the sweep found codes to check at all",
    len(used) >= 10,
    f"{len(used)} uses found — a sweep over nothing passes over anything",
)

# Server identity and capability discovery. The assertions are zugvogel's; the
# values are what run.sh configured, stated here so the call reads as what this
# instance is meant to be.
#
# `oidc_groups_scope=False` is a real assertion, not an omission: this harness
# configures OIDC providers but NO group mapping, and the server must therefore
# not advertise the groups scope. PocketBase rejects an authorization request
# over an unknown scope, so advertising one nobody mapped would break sign-in.
shared_assertions.info(
    h.check,
    h.req,
    "eiermann",
    providers={"oidc", "google"},
    self_signup=False,
    oidc_groups_scope=False,
)

# The geocode route's own contract is zugvogel's to assert — what it refuses,
# what it lets through to fail at the upstream, and the cache's key rounding and
# hit accounting. run.sh points EIERMANN_NOMINATIM_URL at a closed port, which is
# what makes the 400-vs-502 distinction mean anything: it separates "the input
# was rejected" from "the input was accepted and the upstream then failed".
#
# There is no `geocode_walled_off` call: this app's roles are member and
# coordinator, so it has no role walled off from all data, and asserting against
# one that does not exist would pass without testing anything.
status, _ = h.req("GET", "/api/eiermann/geocode?q=Oldenburg")
h.check(
    "the geocode proxy refuses an anonymous caller",
    status == 401,
    f"status {status} — an open proxy burns somebody else's upstream budget",
)

shared_assertions.geocode_validation(h.check, h.req, "eiermann", member_token)

shared_assertions.geocode_cache(
    h.check,
    h.req,
    "eiermann",
    member_token,
    lambda kind, key, response, days: h.mk(T, "geocode_cache", {
        "kind": kind, "cache_key": key, "response": response,
        "result_count": 1, "hits": 0, "expires_at": h.stamp(days=days),
    })["id"],
    lambda row_id: h.req(
        "GET", f"/api/collections/geocode_cache/records/{row_id}", T
    )[1],
)

h.check(
    "the geocode cache is not client-readable",
    h.reads_nothing("geocode_cache", member_token),
    "it holds every address anybody has searched for",
)


# ── The visit transaction ──────────────────────────────────────────────────
#
# The one property everything else rests on: a partial visit must not be
# representable. Seven REST writes would make an aborted round produce a visit in
# which five nests have no check — indistinguishable from five nests somebody
# deliberately did not touch. So the collections are closed and the endpoint is
# the only door.

print("\n[the visit transaction]")

VISIT = "/api/eiermann/visit"


def counts(token):
    """How many visits, checks, eggs and findings exist right now."""
    out = {}
    for name in ("visits", "nest_checks", "nest_eggs", "findings", "follow_ups"):
        _, body = h.req("GET", f"/api/collections/{name}/records?perPage=1", token)
        out[name] = (body or {}).get("totalItems", 0)
    return out


def post_visit(token, payload, key=None):
    return h.req("POST", VISIT, token, payload,
                 headers={"Idempotency-Key": key} if key else None)


vhost = h.mk(coord_token, "spots", {"org": ORG, "name": "Besuchshaus", "phase": "active"})
varea = h.mk(
    coord_token, "areas", {"org": ORG, "spot": vhost["id"], "name": "Dachboden"}
)


def mknest(label, species="feral_pigeon"):
    return h.mk(
        coord_token,
        "nests",
        {"org": ORG, "area": varea["id"], "label": label, "species": species,
         "status": "active"},
    )


vn1 = mknest("V1")
vn2 = mknest("V2")

# The three collections the endpoint owns are closed to clients in every
# direction. This is what makes the transaction the only path.
for name, payload in (
    ("visits", {"org": ORG, "spot": vhost["id"], "visited_at": h.stamp(),
                "outcome": "checked"}),
    ("nest_checks", {"org": ORG, "nest": vn1["id"], "state": "empty",
                     "checked_at": h.stamp()}),
    ("nest_eggs", {"org": ORG, "nest": vn1["id"], "slot_index": 0,
                   "kind": "dummy", "since": h.stamp()}),
):
    status, _ = h.req("POST", f"/api/collections/{name}/records", coord_token, payload)
    h.check(
        f"a client cannot create a {name} row directly",
        status >= 400,
        f"status {status} — the endpoint has to be the only writer, or a "
        "partial visit becomes representable again",
    )

status, _ = h.req("POST", VISIT, None, {"spot": vhost["id"], "outcome": "checked"})
h.check("the endpoint refuses an anonymous caller", status == 401, f"status {status}")

status, _ = post_visit(roleless_token, {"spot": vhost["id"], "outcome": "checked"})
h.check(
    "...and a role-less account",
    status >= 400,
    f"status {status} — a custom route does not inherit the clause every access "
    "rule opens with; forgetting it makes the endpoint the one door a "
    "deactivated account can still walk through",
)

status, _ = post_visit(guest_token, {"spot": vhost["id"], "outcome": "checked"})
h.check(
    "...and a GUEST",
    status >= 400,
    f"status {status} — this endpoint checked `role != null`, the clause "
    "migration 014 replaced everywhere else, and `guest` satisfies it: a "
    "self-registered OAuth2 account behind the wall could write a Besuch. Found "
    "while gating the report routes (eiermann-fi2.8)",
)

# THE ROLLBACK. One good nest and one that does not belong to this Spot: nothing
# at all may be written, because the alternative is a visit that claims one nest
# was checked and says nothing about the other.
other_spot = h.mk(coord_token, "spots", {"org": ORG, "name": "Anderes", "phase": "active"})
other_area = h.mk(
    coord_token, "areas", {"org": ORG, "spot": other_spot["id"], "name": "Fremd"}
)
stranger = h.mk(
    coord_token,
    "nests",
    {"org": ORG, "area": other_area["id"], "label": "X1", "species": "feral_pigeon",
     "status": "active"},
)

before = counts(coord_token)
status, body = post_visit(
    member_token,
    {
        "spot": vhost["id"],
        "outcome": "checked",
        "checks": [
            {"nest": vn1["id"], "state": "empty"},
            {"nest": stranger["id"], "state": "empty"},
        ],
    },
)
h.check("a nest from another Spot is refused", status == 400, f"status {status}")
after = counts(coord_token)
h.check(
    "...and NOTHING was written — the whole visit rolled back",
    after == before,
    f"{before} -> {after}: the first nest's check survived a failure on the "
    "second, which is exactly the state that cannot be told apart from a nest "
    "somebody chose not to touch",
)

status, _ = post_visit(
    member_token,
    {"spot": vhost["id"], "outcome": "checked",
     "checks": [{"nest": vn1["id"], "state": "empty"},
                {"nest": vn1["id"], "state": "swapped"}]},
)
h.check(
    "one nest cannot be checked twice in one visit",
    status == 400,
    f"status {status} — both cannot be true, and the rhythm would apply twice",
)

status, _ = post_visit(
    member_token, {"spot": "nonexistentspot", "outcome": "checked", "checks": []}
)
h.check("a visit to a Spot that does not exist is refused", status == 400)

status, _ = post_visit(member_token, {"spot": vhost["id"], "outcome": "skipped"})
h.check(
    "a skipped visit needs a reason",
    status == 400,
    f"status {status} — without one the record cannot say whether anybody tried",
)

status, _ = post_visit(
    member_token,
    {"spot": vhost["id"], "outcome": "skipped", "skip_reason": "no_key",
     "checks": [{"nest": vn1["id"], "state": "empty"}]},
)
h.check(
    "a skipped visit cannot carry nest checks",
    status == 400,
    f"status {status} — a skip documents a non-event; a check inside one is an "
    "observation, and the rhythm would advance on a nest nobody saw",
)

# The arithmetic is the server's.
for label, payload, why in (
    ("more real eggs removed than were there",
     {"state": "swapped", "real_before": 1, "removed_real": 3, "added_dummy": 3},
     "the count would go negative"),
    ("client numbers that do not add up",
     {"state": "swapped", "real_before": 2, "removed_real": 2, "added_dummy": 2,
      "real_after": 2, "dummy_after": 0},
     "the two sides disagree about what happened, and overwriting would hide a "
     "bug in the form"),
):
    body = dict(payload)
    body["nest"] = vn1["id"]
    status, _ = post_visit(
        member_token,
        {"spot": vhost["id"], "outcome": "checked", "checks": [body]},
    )
    h.check(f"refused: {label}", status == 400, f"status {status} — {why}")

# A real round.
status, body = post_visit(
    member_token,
    {
        "spot": vhost["id"],
        "outcome": "checked",
        "note": "Erste Runde",
        "checks": [
            {"nest": vn1["id"], "state": "swapped", "real_before": 2,
             "dummy_before": 0, "removed_real": 2, "added_dummy": 2},
            {"nest": vn2["id"], "state": "swapped", "real_before": 2,
             "dummy_before": 0, "removed_real": 1, "added_dummy": 1},
        ],
        "findings": [{"kind": "dead_bird", "count": 1, "note": "unter dem Fenster"}],
    },
    key="suite-round-1",
)
h.check("a complete visit is accepted", status == 200, f"status {status} {body}")
written = {c["nest"]: c["state"] for c in (body or {}).get("checks") or []}
h.check(
    "a swap that leaves a real egg behind is RECONCILED to partial",
    written.get(vn2["id"]) == "partial",
    f"{written} — the client called it swapped; the follow-up that keeps a half "
    "clutch from hatching unnoticed hangs off this flag, so it is derived from "
    "the arithmetic rather than trusted",
)
h.check(
    "...and a clean swap stays swapped",
    written.get(vn1["id"]) == "swapped",
    str(written),
)

_, eggs = h.req(
    "GET",
    f"/api/collections/nest_eggs/records?filter=nest='{vn2['id']}'&sort=slot_index",
    member_token,
)
kinds = [e["kind"] for e in (eggs or {}).get("items") or []]
h.check(
    "the nest now holds exactly what the check says",
    kinds == ["real", "dummy"],
    f"{kinds} — nest_eggs is derived from the checks; two writers of derived "
    "state drift and no screen can show which is wrong",
)

_, ups = h.req(
    "GET",
    f"/api/collections/follow_ups/records?filter=nest='{vn2['id']}'",
    member_token,
)
open_ups = [
    f for f in (ups or {}).get("items") or [] if not f.get("resolved_at")
]
h.check(
    "the Halbgelege created a Nachkontrolle",
    len(open_ups) == 1 and open_ups[0]["reason"] == "half_clutch",
    f"{[(f['reason'], f.get('due_at')) for f in open_ups]} — this is field "
    "problem two: the half clutch is missed, the nest comes round on the normal "
    "rhythm, and by then the remaining egg has hatched",
)

_, spot_now = h.req(
    "GET", f"/api/collections/spots/records/{vhost['id']}", member_token
)
h.check(
    "the Spot's due date is the follow-up, not the ladder",
    (spot_now or {}).get("next_due_at", "")[:10] == open_ups[0]["due_at"][:10],
    f"spot {spot_now and spot_now.get('next_due_at')} vs follow-up "
    f"{open_ups[0]['due_at']} — the Nachkontrolle is earlier, so it wins the "
    "minimum; that is the entire point of it",
)

# The retry button. Three presses, one visit.
before = counts(coord_token)
for attempt in range(3):
    status, replayed = post_visit(
        member_token,
        {
            "spot": vhost["id"],
            "outcome": "checked",
            "note": "Erste Runde",
            "checks": [
                {"nest": vn1["id"], "state": "swapped", "real_before": 2,
                 "dummy_before": 0, "removed_real": 2, "added_dummy": 2},
                {"nest": vn2["id"], "state": "swapped", "real_before": 2,
                 "dummy_before": 0, "removed_real": 1, "added_dummy": 1},
            ],
            "findings": [
                {"kind": "dead_bird", "count": 1, "note": "unter dem Fenster"}
            ],
        },
        key="suite-round-1",
    )
    h.check(
        f"retry {attempt + 1} replays the stored response",
        status == 200 and (replayed or {}).get("visit") == body.get("visit"),
        f"status {status}, visit {(replayed or {}).get('visit')} vs "
        f"{body.get('visit')}",
    )
h.check(
    "...and no second visit was written",
    counts(coord_token) == before,
    "'press it three times' has to mean three times, or the retry button "
    "produces the damage it exists to avoid",
)

status, reused = post_visit(
    member_token,
    {"spot": vhost["id"], "outcome": "skipped", "skip_reason": "no_key"},
    key="suite-round-1",
)
h.check(
    "the same key with a DIFFERENT body is a 409",
    status == 409,
    f"status {status} — answering with the first visit's response would mean "
    "the second visit is never written while the app reports success",
)

# Order-independence: the same body with its JSON keys shuffled is the same
# request. `e.requestInfo().body` arrives from a Go map, whose iteration order Go
# randomises, so a naive hash of it differs on every request and turns every
# legitimate retry into a 409.
status, shuffled = post_visit(
    member_token,
    {
        "findings": [
            {"note": "unter dem Fenster", "count": 1, "kind": "dead_bird"}
        ],
        "checks": [
            {"added_dummy": 2, "state": "swapped", "nest": vn1["id"],
             "removed_real": 2, "dummy_before": 0, "real_before": 2},
            {"added_dummy": 1, "state": "swapped", "nest": vn2["id"],
             "removed_real": 1, "dummy_before": 0, "real_before": 2},
        ],
        "note": "Erste Runde",
        "outcome": "checked",
        "spot": vhost["id"],
    },
    key="suite-round-1",
)
h.check(
    "reordered JSON keys still count as the same request",
    status == 200 and (shuffled or {}).get("visit") == body.get("visit"),
    f"status {status} — the fingerprint has to be canonical, or a client that "
    "re-serialises its body between attempts cannot retry at all",
)


# ── The ladder, through the endpoint ───────────────────────────────────────

print("\n[the rhythm]")

ladder_nest = mknest("L1")


def empty_check(nest_id, when):
    status, _ = post_visit(
        member_token,
        {"spot": vhost["id"], "outcome": "checked", "visited_at": when,
         "checks": [{"nest": nest_id, "state": "empty"}]},
    )
    return status


def nest_now(nest_id):
    _, body = h.req(
        "GET", f"/api/collections/nests/records/{nest_id}", member_token
    )
    return body or {}


for i in range(3):
    empty_check(ladder_nest["id"], h.stamp(days=-30 + i))
state = nest_now(ladder_nest["id"])
h.check(
    "three empty checks advance the ladder one rung",
    state.get("empty_streak") == 3 and state.get("interval_days") == 14,
    f"streak={state.get('empty_streak')} interval={state.get('interval_days')}",
)

for i in range(3):
    empty_check(ladder_nest["id"], h.stamp(days=-20 + i))
state = nest_now(ladder_nest["id"])
h.check(
    "six advance it to the cap",
    state.get("empty_streak") == 6 and state.get("interval_days") == 28,
    f"streak={state.get('empty_streak')} interval={state.get('interval_days')}",
)

status, _ = post_visit(
    member_token,
    {"spot": vhost["id"], "outcome": "checked", "visited_at": h.stamp(days=-1),
     "checks": [{"nest": ladder_nest["id"], "state": "swapped", "real_before": 1,
                 "dummy_before": 0, "removed_real": 1, "added_dummy": 1}]},
)
state = nest_now(ladder_nest["id"])
h.check(
    "one egg drops it straight back to base, from any height",
    state.get("empty_streak") == 0 and state.get("interval_days") == 7,
    f"streak={state.get('empty_streak')} interval={state.get('interval_days')} — "
    "the two errors do not cost the same: checking a dead nest too often wastes "
    "an hour, checking a live one too rarely means a clutch hatches",
)

unreached = mknest("U1")
empty_check(unreached["id"], h.stamp(days=-10))
before_state = nest_now(unreached["id"])
status, _ = post_visit(
    member_token,
    {"spot": vhost["id"], "outcome": "checked", "visited_at": h.stamp(),
     "checks": [{"nest": unreached["id"], "state": "not_reachable"}]},
)
h.check("a not_reachable check is accepted", status == 200, f"status {status}")
after_state = nest_now(unreached["id"])
h.check(
    "...and moves the rhythm NOT AT ALL",
    (after_state.get("empty_streak"), after_state.get("next_due_at"))
    == (before_state.get("empty_streak"), before_state.get("next_due_at")),
    f"{before_state.get('empty_streak')}/{before_state.get('next_due_at')} -> "
    f"{after_state.get('empty_streak')}/{after_state.get('next_due_at')} — "
    "somebody tried and could not get to it; treating that as 'looked, found "
    "nothing' stretches the interval on a nest nobody has seen, the one "
    "direction the rhythm must never drift",
)

# The Ist-Gelege is derived state, so a check that says "nothing in there" has
# to leave nothing in there. Without this the dossier reads "1 Kunstei" for a
# nest somebody just recorded as empty, and the packing count tells the next
# volunteer to bring nothing.
#
# On the nests this section already built rather than on fresh ones: the factory
# rate limit is 20 creates per 5 seconds (zv_rate_limits.js), and a suite that
# spends them on fixtures it does not need fails later, elsewhere, as a 429 that
# reads like a broken rule.


def egg_kinds(nest_id):
    _, eggs = h.req(
        "GET",
        f"/api/collections/nest_eggs/records?filter=nest='{nest_id}'"
        "&sort=slot_index&perPage=200",
        member_token,
    )
    return [e["kind"] for e in (eggs or {}).get("items") or []]


h.check(
    "the swap left a dummy in the nest to begin with",
    egg_kinds(ladder_nest["id"]) == ["dummy"],
    f"{egg_kinds(ladder_nest['id'])} — the rest of this block means nothing "
    "without something in there to clear",
)

# The two states that must NOT clear it. `untouched` is the one a screen would
# notice; `not_reachable` is the observation-versus-non-observation rule the
# ladder follows as well — deleting the contents of a nest nobody looked into is
# the same mistake as advancing the interval on it.
for state in ("untouched", "not_reachable"):
    status, _ = post_visit(
        member_token,
        {"spot": vhost["id"], "outcome": "checked", "visited_at": h.stamp(),
         "checks": [{"nest": ladder_nest["id"], "state": state}]},
    )
    h.check(
        f"a {state} check leaves the Ist-Gelege alone",
        status == 200 and egg_kinds(ladder_nest["id"]) == ["dummy"],
        f"status {status}, eggs {egg_kinds(ladder_nest['id'])}",
    )

status, _ = post_visit(
    member_token,
    {"spot": vhost["id"], "outcome": "checked", "visited_at": h.stamp(),
     "checks": [{"nest": ladder_nest["id"], "state": "empty"}]},
)
h.check("an empty check is accepted", status == 200, f"status {status}")
h.check(
    "an EMPTY check clears the Ist-Gelege",
    egg_kinds(ladder_nest["id"]) == [],
    f"{egg_kinds(ladder_nest['id'])} — 'nothing in the nest' and 'one Kunstei "
    "in the nest' cannot both be true; that count feeds the dossier line AND "
    "the Attrappen somebody packs",
)

# `gone` too: there is nowhere left for an egg to be.
status, _ = post_visit(
    member_token,
    {"spot": vhost["id"], "outcome": "checked", "visited_at": h.stamp(),
     "checks": [{"nest": unreached["id"], "state": "swapped", "real_before": 1,
                 "dummy_before": 0, "removed_real": 1, "added_dummy": 1}]},
)
h.check(
    "a swap fills the nest that is about to disappear",
    status == 200 and egg_kinds(unreached["id"]) == ["dummy"],
    f"status {status}, eggs {egg_kinds(unreached['id'])}",
)
status, _ = post_visit(
    member_token,
    {"spot": vhost["id"], "outcome": "checked", "visited_at": h.stamp(),
     "checks": [{"nest": unreached["id"], "state": "gone"}]},
)
h.check("a gone check is accepted", status == 200, f"status {status}")
h.check(
    "...and it clears the Ist-Gelege with the nest",
    egg_kinds(unreached["id"]) == [],
    str(egg_kinds(unreached["id"])),
)

# A later check on the nest settles the Nachkontrolle — not time passing.
status, _ = post_visit(
    member_token,
    {"spot": vhost["id"], "outcome": "checked", "visited_at": h.stamp(),
     "checks": [{"nest": vn2["id"], "state": "swapped", "real_before": 1,
                 "dummy_before": 1, "removed_real": 1, "added_dummy": 1}]},
)
h.check("the return visit completes the swap", status == 200, f"status {status}")
_, ups = h.req(
    "GET",
    f"/api/collections/follow_ups/records?filter=nest='{vn2['id']}'",
    member_token,
)
items = (ups or {}).get("items") or []
h.check(
    "the Nachkontrolle is resolved by the check that completed the swap",
    all(f.get("resolved_at") for f in items),
    f"{[(f['reason'], f.get('resolved_at')) for f in items]}",
)
h.check(
    "...and no second one was stacked on top",
    len([f for f in items if not f.get("resolved_at")]) == 0,
    "a nest that is partial twice running would otherwise show up twice in the "
    "due list with two dates",
)

# The protected guard, on the transactional path.
guarded = mknest("P1", species="protected")
before = counts(coord_token)
status, body = post_visit(
    member_token,
    {"spot": vhost["id"], "outcome": "checked",
     "checks": [
         {"nest": vn1["id"], "state": "empty"},
         {"nest": guarded["id"], "state": "swapped", "real_before": 2,
          "dummy_before": 0, "removed_real": 2, "added_dummy": 2},
     ]},
)
h.check(
    "an egg swap on a protected nest is refused",
    status == 400,
    f"status {status}",
)
h.check(
    "...with the code that names the reason",
    refused_with(body, "nest_protected_no_egg_changes"),
    str(refusal_codes(body)),
)
h.check(
    "...and the OTHER nest's check rolled back with it",
    counts(coord_token) == before,
    "a warning would be the wrong shape here: §44 BNatSchG is not advisory, so "
    "the visit fails rather than writing the rest and skipping this nest",
)

status, _ = post_visit(
    member_token,
    {"spot": vhost["id"], "outcome": "checked",
     "checks": [{"nest": guarded["id"], "state": "untouched",
                 "note": "Dohle sitzt drauf"}]},
)
h.check(
    "but the nest can still be OBSERVED and noted",
    status == 200,
    f"status {status} — the guard is on touching the eggs, not on recording "
    "what is there",
)

undetermined = mknest("Q1", species="unknown")
status, _ = post_visit(
    member_token,
    {"spot": vhost["id"], "outcome": "checked",
     "checks": [{"nest": undetermined["id"], "state": "protected",
                 "species_label": "Turmfalke"}]},
)
h.check("a nest can be reported protected on a visit", status == 200, f"status {status}")
state = nest_now(undetermined["id"])
h.check(
    "...and the NEST is marked, not just the check",
    state.get("species") == "protected" and state.get("species_label") == "Turmfalke",
    f"species={state.get('species')!r} label={state.get('species_label')!r} — "
    "recording only the check would leave the egg-swap path open next visit",
)
h.check(
    "...and it leaves the due lists",
    not state.get("next_due_at"),
    "nothing may be DONE there, and a work list that keeps offering an item "
    "nobody may act on trains people to ignore the list",
)


# ── nest_state ─────────────────────────────────────────────────────────────
#
# The nest list in the dossier reads this and nothing else, so the same two
# things hold as for spot_overview: a view does NOT inherit the rules of the
# tables under it, and its computed columns are a contract the client sorts and
# draws by.
#
# Placed here on purpose — after the rhythm and the protected-species sections —
# because the interesting rows only exist once something has driven them: a nest
# with eggs in it, a nest the ladder has given a due date, and a nest a visit
# reported as protected.

print("\n[nest_state]")

status, body = h.req("GET", "/api/collections/nest_state/records", member_token)
h.check("a member reads the nest states", status == 200, f"status {status}")
h.check("...and it has rows", bool((body or {}).get("items")))

h.check(
    "the view is NOT readable anonymously",
    h.reads_nothing("nest_state"),
    "a view does not inherit the rules of the tables under it",
)
h.check(
    "a role-less account reads no nest states",
    h.reads_nothing("nest_state", roleless_token),
)

status, _ = h.req(
    "POST", "/api/collections/nest_state/records", coord_token,
    {"org": ORG, "label": "nope"},
)
h.check("the view is not writable, by anybody", status >= 400, f"status {status}")

# Created by a member OF that org, not by the superuser: the nest hook derives
# `spot` from the area and checks the area against the CALLER's org, and a
# superuser has no org at all — measured, a superuser cannot create a nest.
foreign_member = h.mkuser(
    T, "fremd@eiermann.test", "member", "org00000foreign"
)
_, foreign_token = h.login("fremd@eiermann.test", h.user_pass)
foreign_nest = h.mk(
    foreign_token,
    "nests",
    {"org": "org00000foreign", "area": foreign_area["id"], "label": "F1",
     "species": "feral_pigeon", "status": "active"},
)
h.check(
    "another org's nest is not in the view at all",
    h.reads_nothing("nest_state", member_token, record_id=foreign_nest["id"]),
    "org scope on the view itself, not borrowed from `nests`",
)


def state_of(nest_id):
    _, body = h.req(
        "GET", f"/api/collections/nest_state/records/{nest_id}", member_token
    )
    return body or {}


# The counts ARE the Ist-Gelege, so they have to equal the rows they count. A
# view that drifted here would show a swapped nest as empty — which reads as
# "nothing to pack" at the car.
_, eggs = h.req(
    "GET",
    f"/api/collections/nest_eggs/records?filter=nest='{vn2['id']}'&perPage=200",
    coord_token,
)
egg_rows = (eggs or {}).get("items") or []
real = len([e for e in egg_rows if e.get("kind") == "real"])
dummy = len([e for e in egg_rows if e.get("kind") == "dummy"])
row = state_of(vn2["id"])
h.check(
    "the egg counts equal the egg rows",
    row.get("real_count") == real and row.get("dummy_count") == dummy,
    f"view says {row.get('real_count')}/{row.get('dummy_count')}, "
    f"nest_eggs has {real}/{dummy}",
)
h.check(
    "...and there were eggs to count in the first place",
    real + dummy > 0,
    "a count of zero against zero rows would pass over a broken subquery",
)
h.check(
    "the oldest egg's date comes out as the raw stored value",
    row.get("oldest_since") == min(e.get("since") for e in egg_rows),
    f"{row.get('oldest_since')!r} — the client subtracts these dates, so a "
    "value computed in SQL would be a day out in CET",
)

# The urgency ladder. Everything the client sorts by, and three of the six rungs
# cannot be reached by writing a field: `next_due_at` is refused from a client,
# so a due rank exists only where the rhythm put one.
gone_nest = mknest("G1")
status, _ = h.req(
    "PATCH", f"/api/collections/nests/records/{gone_nest['id']}", coord_token,
    {"status": "gone"},
)
h.check("a nest can be recorded as gone", h.ok(status), f"status {status}")
h.check(
    "a gone nest ranks last",
    state_of(gone_nest["id"]).get("urgency") == 5,
    f"rank {state_of(gone_nest['id']).get('urgency')} — it is recorded history, "
    "not work",
)
h.check(
    "a protected nest has a rank of its OWN, not a due rank",
    state_of(undetermined["id"]).get("urgency") == 4,
    f"rank {state_of(undetermined['id']).get('urgency')} — nothing may be done "
    "there, and it must still be visible before somebody goes up",
)
fresh = mknest("N0")
h.check(
    "a nest with no due date yet ranks as in-rhythm, not overdue",
    state_of(fresh["id"]).get("urgency") == 3,
    "a nest nobody has checked is not overdue, and painting every fresh nest "
    "red is how a colour stops being read",
)

# eiermann-uga. The rank-2 window is a QUARTER of the nest's own interval,
# rounded up — not a fixed week. So a nest the rhythm just dated a full interval
# out is IN RHYTHM, and rank 2 has gone back to meaning "actually soon".
#
# Both ends are asserted, because either one alone passes on a broken ladder:
# while the window was a fixed `+7 days` and the base interval was 7, every
# freshly checked nest ranked 2 and rank 3 could not be reached at all.
due_row = state_of(ladder_nest["id"])
due = (due_row.get("next_due_at") or "")[:10]
today = h.stamp()[:10]
h.check(
    "a nest dated a FULL interval out is in rhythm, not due-soon",
    due > today and due_row.get("urgency") == 3,
    f"due {due!r} against today {today!r} ranked {due_row.get('urgency')} — "
    "with a window as wide as the interval, rank 3 is unreachable and "
    '"diese Woche faellig" is a healthy nest\'s whole cycle',
)

# The other end, reached through the RHYTHM rather than by writing the field:
# `next_due_at` is refused from a client, so the only way in is a check with a
# backdated `visited_at`. A base-interval nest checked five days ago is due in
# two, and its window is ceil(7 / 4) = 2 — so it lands on rank 2.
soon = mknest("S1")
h.check(
    "a nest can be checked with a backdated visit",
    h.ok(empty_check(soon["id"], h.stamp(days=-5))),
)
soon_row = state_of(soon["id"])
h.check(
    "a nest INSIDE its proportional window ranks due-soon",
    soon_row.get("urgency") == 2,
    f"due {(soon_row.get('next_due_at') or '')[:10]!r} against today {today!r} "
    f"ranked {soon_row.get('urgency')}, expected 2",
)


# ── eiermann-bbj: every rung of both ladders is REACHABLE ──────────────────
#
# The window bug (eiermann-uga) survived because nothing asked whether a rung
# could be reached AT ALL. `inRhythm` was impossible at the base interval, and
# every individual row was still coloured correctly — the ladder as a whole was
# broken and no single assertion could see it. A rung that no state of the world
# produces is dead code wearing the shape of a feature.
#
# So the ladders are asserted as a CENSUS: every rank gets a case that produces
# it, the observed ranks are compared against the full range, and anything
# nobody reached fails by name. That is the half a per-case test cannot do — a
# rung added later with no case fails here, and a rung that quietly became
# unreachable fails here too.
#
# `spots.next_due_at` is client-writable, so the Spot dates are set directly.
# `nests.next_due_at` is NOT — it is refused from a client — so every nest rank
# is reached through the rhythm, with a backdated `visited_at` doing the work a
# PATCH cannot.

SPOT_RUNGS = {0: "overdue", 1: "due today", 2: "due soon", 3: "in rhythm",
              4: "prospect", 5: "paused", 6: "closed"}
NEST_RUNGS = {0: "overdue", 1: "due today", 2: "due soon", 3: "in rhythm",
              4: "protected", 5: "gone"}


def spot_at(name, phase="active", due=None, **fields):
    """An active Spot dated [due] days out, or one in another [phase]."""
    row = h.mk(
        coord_token, "spots", {"org": ORG, "name": name, "phase": phase, **fields}
    )
    if due is not None:
        h.req(
            "PATCH", f"/api/collections/spots/records/{row['id']}", T,
            {"next_due_at": h.stamp(days=due)},
        )
    return row


# Rank 2 needs the date INSIDE the window, and for a Spot created just now the
# window is ceil(daysUntil / 4) — so only tomorrow qualifies. That is not a
# quirk of the test: the reconstruction anchor is the last checked visit, and a
# Spot nobody has visited has only its creation to count from.
seen_spot = {
    0: urgency_of(spot_at("Leiter überfällig", due=-3)["id"]),
    1: urgency_of(spot_at("Leiter heute", due=0)["id"]),
    2: urgency_of(spot_at("Leiter bald", due=1)["id"]),
    3: urgency_of(spot_at("Leiter im Rhythmus", due=7)["id"]),
    4: urgency_of(spot_at("Leiter Erkundung", phase="prospect")["id"]),
    # A pause is refused without a reason (`spot_pause_needs_reason`), which is
    # itself the rule that a pause somebody has to explain is one they mean.
    5: urgency_of(
        spot_at("Leiter pausiert", phase="paused",
                pause_reason="Gerüst am Haus")["id"]
    ),
    6: urgency_of(
        spot_at("Leiter geschlossen", phase="closed", closed_reason="netted")["id"]
    ),
}
for rung, label in SPOT_RUNGS.items():
    h.check(
        f"a Spot can reach urgency {rung} ({label})",
        seen_spot.get(rung) == rung,
        f"the case built for {label} ranked {seen_spot.get(rung)} — a rung "
        "nothing can produce is dead code that looks like a feature",
    )
h.check(
    "the Spot ladder has no rung this suite cannot reach",
    set(seen_spot) == set(SPOT_RUNGS),
    f"reached {sorted(seen_spot)} of {sorted(SPOT_RUNGS)}",
)

# And the point of the whole change: the window is PROPORTIONAL, so the same
# number of days until the date lands on different rungs depending on the
# interval behind it. Both of these are due in three days. The first has only
# its creation to count from, so its interval reads as three days and its window
# as one. The second was last checked 27 days ago, so its interval reads as 30
# and its window as 8 — and three days out is inside that.
#
# This is the assertion a fixed window cannot pass, whatever number it is fixed
# at: one window cannot be both narrower and wider than three days.
near = spot_at("Kurzer Rhythmus", due=3)
far = h.mk(coord_token, "spots", {"org": ORG, "name": "Langer Rhythmus",
                                  "phase": "active"})
status, _ = post_visit(
    member_token,
    {"spot": far["id"], "outcome": "checked", "visited_at": h.stamp(days=-27),
     "checks": []},
)
h.check("a Spot with no nests can be recorded as checked", h.ok(status),
        f"status {status}")
# After the visit, because the visit endpoint recomputes the date it would
# otherwise overwrite.
h.req("PATCH", f"/api/collections/spots/records/{far['id']}", T,
      {"next_due_at": h.stamp(days=3)})
h.check(
    "the same three days out ranks differently on a short and a long rhythm",
    urgency_of(near["id"]) == 3 and urgency_of(far["id"]) == 2,
    f"short rhythm ranked {urgency_of(near['id'])} (want 3, outside its "
    f"one-day window), long rhythm ranked {urgency_of(far['id'])} (want 2, "
    "inside its eight-day window) — a FIXED window cannot produce both",
)

# The nest rungs. Every date here is the rhythm's own work: one empty check with
# a backdated visit puts `next_due_at` a base interval after that date, so the
# backdating chooses the rung.
gone_two = mknest("LG")
h.req("PATCH", f"/api/collections/nests/records/{gone_two['id']}", coord_token,
      {"status": "gone"})
prot_two = mknest("LP", species="protected")


def nest_rank_after(label, days_ago):
    nest = mknest(label)
    h.check(
        f"the rhythm accepts a check {days_ago} days back for {label}",
        h.ok(empty_check(nest["id"], h.stamp(days=days_ago))),
    )
    return state_of(nest["id"]).get("urgency")


seen_nest = {
    0: nest_rank_after("L0", -10),
    1: nest_rank_after("L1x", -7),
    2: nest_rank_after("L2", -5),
    3: state_of(mknest("L3")["id"]).get("urgency"),
    4: state_of(prot_two["id"]).get("urgency"),
    5: state_of(gone_two["id"]).get("urgency"),
}
for rung, label in NEST_RUNGS.items():
    h.check(
        f"a nest can reach urgency {rung} ({label})",
        seen_nest.get(rung) == rung,
        f"the case built for {label} ranked {seen_nest.get(rung)}",
    )
h.check(
    "the nest ladder has no rung this suite cannot reach",
    set(seen_nest) == set(NEST_RUNGS),
    f"reached {sorted(seen_nest)} of {sorted(NEST_RUNGS)}",
)


# ── The shapes the chronology actually asks for ────────────────────────────
#
# eiermann-3is.5. These are not access-rule assertions: the rules above already
# cover who may read `visits`, `nest_checks` and `findings`. What is asserted
# here is that the QUERIES the dossier's chronology sends parse and return
# something — and that is worth a test because every one of them fails as a
# generic 400 that a widget test with a mocked repository cannot see.
#
# Three shapes, one per way the client can be wrong:
#
#   * keyset paging on `visited_at`, which is a DATE field compared as a string;
#   * an OR chain standing in for the `IN` PocketBase does not have;
#   * `expand` across a relation whose own collection has its own rules.
#
# The last one is the one that would have hurt: an expand the rules refuse comes
# back as a row with the key simply absent, so the label goes missing and the
# chronology prints "Nest unbekannt" for every line — a silent, plausible,
# completely wrong screen.

print("\n[die Chronologie liest]")

_, page = h.req(
    "GET",
    "/api/collections/visits/records?filter="
    + urllib.parse.quote(f"spot='{vhost['id']}'")
    + "&sort=-visited_at,-id&perPage=20&skipTotal=1",
    member_token,
)
chrono_visits = (page or {}).get("items") or []
h.check(
    "the visits of one building page by the date the visit HAPPENED",
    bool(chrono_visits),
    f"{page} — not by `created`: the flow holds everything in memory until the "
    "last button, so an evening entry is an afternoon visit, and a chronology "
    "ordered by the write date reorders itself for a reason nothing on screen "
    "explains",
)
h.check(
    "...newest first",
    [v.get("visited_at") for v in chrono_visits]
    == sorted((v.get("visited_at") for v in chrono_visits), reverse=True),
    str([v.get("visited_at") for v in chrono_visits]),
)

# The OR chain, over the whole page at once. One request and not one per row: a
# chronology that fetched per visit is twenty requests for a screen.
ids = [v["id"] for v in chrono_visits]
# Percent-encoded here because this suite builds its URLs by hand; the Dart SDK
# does it for the app. The chain itself is what is under test.
or_chain = urllib.parse.quote(" || ".join(f"visit='{i}'" for i in ids))
_, checks_page = h.req(
    "GET",
    f"/api/collections/nest_checks/records?filter={or_chain}"
    "&sort=checked_at,nest&expand=nest&perPage=200",
    member_token,
)
chrono_checks = (checks_page or {}).get("items") or []
h.check(
    "an OR chain stands in for the IN that PocketBase does not have",
    bool(chrono_checks),
    f"{checks_page} — a filter that does not parse comes back as a generic 400, "
    "and a widget test against a mocked repository cannot see it",
)
h.check(
    "...and every check carries its nest LABEL, not just an id",
    all(
        (c.get("expand") or {}).get("nest", {}).get("label")
        for c in chrono_checks
    ),
    f"{[c.get('expand') for c in chrono_checks][:2]} — an expand the rules "
    "refuse is not an error: the key is simply absent, the label goes missing, "
    "and the chronology prints 'Nest unbekannt' on every line. Silent, "
    "plausible and completely wrong",
)

_, finds_page = h.req(
    "GET",
    f"/api/collections/findings/records?filter={or_chain}"
    "&sort=found_at&expand=nest&perPage=200",
    member_token,
)
h.check(
    "the Funde of the same page come back the same way",
    bool((finds_page or {}).get("items")),
    str(finds_page),
)

# The org-wide list behind the dashboard number, and the number itself.
_, recent = h.req(
    "GET",
    "/api/collections/findings/records?sort=-found_at,-id&expand=spot,nest"
    "&perPage=30&skipTotal=1",
    member_token,
)
recent_items = (recent or {}).get("items") or []
h.check(
    "the org-wide Funde list names the BUILDING",
    bool(recent_items)
    and all(
        (f.get("expand") or {}).get("spot", {}).get("name") for f in recent_items
    ),
    f"{[f.get('expand') for f in recent_items][:2]} — this list spans "
    "buildings, and the building is the first thing somebody needs from it",
)

_, counted = h.req(
    "GET",
    "/api/collections/findings/records?perPage=1"
    "&filter=" + urllib.parse.quote(f"found_at>='{h.stamp(days=-30)}'"),
    member_token,
)
h.check(
    "the dashboard's number is a SERVER-side count over a window",
    (counted or {}).get("totalItems", 0) > 0,
    f"{counted} — one number is the whole answer, so pulling every row over "
    "the wire to call length on it is the same request with a payload nobody "
    "reads",
)
h.check(
    "...and a guest counts nothing",
    h.reads_nothing("findings", guest_token),
    "the count goes through the same list rule as the rows",
)


# ── species_labels: the vocabulary that grows from use ──────────────────────
#
# eiermann-3is.1. The app does not identify species — it takes the word of the
# person standing in front of the nest — so the picker behind that field is a
# view over what has actually been typed, per org. Three properties are worth a
# test, and the first two are the reason the view is a UNION at all.

print("\n[species_labels]")

# One word, used once in EACH table under the view: a jackdaw nest in the attic
# and a dead jackdaw on the floor below it. Same vocabulary, two writers.
sl_nest = h.mk(
    coord_token,
    "nests",
    {"org": ORG, "area": varea["id"], "label": "SL1", "species": "protected",
     "species_label": "Mauersegler", "status": "active"},
)
status, _ = post_visit(
    member_token,
    {
        "spot": vhost["id"],
        "outcome": "checked",
        "checks": [],
        "findings": [
            {"kind": "dead_bird", "count": 1, "species_label": "Mauersegler"},
            # A second word from the findings side alone, and one with NO label
            # at all: the empty one must not become a row, or the picker offers
            # a blank entry that looks like a bug in the app.
            {"kind": "other_species", "count": 2,
             "species_label": "Gartenrotschwanz"},
            {"kind": "site_change", "note": "Netz an der Nordseite"},
        ],
    },
    key="suite-species-labels",
)
h.check("a visit may carry species labels", status == 200, f"status {status}")

status, body = h.req(
    "GET",
    "/api/collections/species_labels/records?perPage=200",
    member_token,
)
h.check("a member reads the species labels", status == 200, f"status {status}")
rows = {r["label"]: r for r in (body or {}).get("items") or []}
h.check(
    "a label recorded on a NEST is in the vocabulary",
    "Mauersegler" in rows,
    f"{sorted(rows)} — nest {sl_nest['id']} named it; a view over findings "
    "alone would make the volunteer who named the nest re-type the word, and "
    "re-type it differently",
)
h.check(
    "a label recorded on a FINDING is in the vocabulary",
    "Gartenrotschwanz" in rows,
    f"{sorted(rows)} — this half is the one the finding form reads back",
)
h.check(
    "one word used in both tables is ONE row, counted twice",
    rows.get("Mauersegler", {}).get("used_count") == 2,
    f"{rows.get('Mauersegler')} — UNION ALL then GROUP BY: deduplicating "
    "before the count would rank a word typed in both places below one typed "
    "once, and "
    "the count is what orders the picker",
)
h.check(
    "...and the count is a NUMBER, not a quoted one",
    isinstance(rows.get("Mauersegler", {}).get("used_count"), int),
    f"{rows.get('Mauersegler', {}).get('used_count')!r} — a computed view column "
    "falls back to type json, so anything but a bare integer expression "
    "arrives as a string and every client comparison silently compares text",
)
h.check(
    "an empty species label is not a row",
    all(r["label"] for r in (body or {}).get("items") or []),
    f"{sorted(rows)} — the site_change finding carries no species, and a blank "
    "suggestion in the picker reads as a bug in the app",
)
h.check(
    "every row carries the org the label was typed in",
    all(r.get("org") == ORG for r in (body or {}).get("items") or []),
    "the id is org-prefixed for the same reason: two organisations that both "
    "wrote 'Mauersegler' are two rows, and a colliding id is one org's row "
    "read for the other's",
)

h.check(
    "the view is NOT readable anonymously",
    h.reads_nothing("species_labels"),
    "a view does not inherit the rules of the tables under it",
)
h.check(
    "a role-less account reads no species labels",
    h.reads_nothing("species_labels", roleless_token),
)

status, _ = h.req(
    "POST", "/api/collections/species_labels/records", coord_token,
    {"org": ORG, "label": "Wanderfalke"},
)
h.check(
    "the vocabulary is not writable, by anybody",
    status >= 400,
    f"status {status} — it grows by being USED; a writable list is a curated "
    "list, which is the thing this view exists instead of",
)

# The other org's word, typed by a member of that org: the scope has to come
# from the view's own rule, not from `findings` and `nests` underneath it.
h.mk(
    foreign_token,
    "nests",
    {"org": "org00000foreign", "area": foreign_area["id"], "label": "F2",
     "species": "protected", "species_label": "Fremdvogel", "status": "active"},
)
_, mine = h.req(
    "GET",
    "/api/collections/species_labels/records?perPage=200",
    member_token,
)
h.check(
    "another org's vocabulary is not in mine",
    all(
        r["label"] != "Fremdvogel" for r in (mine or {}).get("items") or []
    ),
    f"{sorted(r['label'] for r in (mine or {}).get('items') or [])} — a "
    "vocabulary is a record of what this group has seen, and leaking it "
    "leaks where another group works",
)


# ── Touren: the template, the route, the round ──────────────────────────────
#
# eiermann-avq.6. Three collections and one field on `visits`, and the property
# they exist to hold: a round says truthfully what was walked, under what name,
# by whom, and when it ended.
#
# Two of the three have a `createRule` of the form "the body's org is my org"
# while pointing at a row the caller names by id — trap 11 in the same shape it
# bit `nests`. Those are the assertions that matter most here; the rest is the
# one-way door of `finished_at` and the snapshots that let a run outlive its
# template.

print("\n[Touren]")

# A second member, so "your own open round" can be told from "somebody else's".
other_member = h.mk(
    coord_token,
    "users",
    {
        "email": "zweite@eiermann.test",
        "password": h.user_pass,
        "passwordConfirm": h.user_pass,
        "org": ORG,
        "role": "member",
        "is_active": True,
    },
)
_, other_token = h.login("zweite@eiermann.test")
h.check("a second member can sign in", other_token is not None)

tour = h.mk(
    member_token,
    "tours",
    {"org": ORG, "name": "Tour 1", "is_active": True, "sort_index": 0},
)
h.check(
    "a member — not only the coordination — can build a route template",
    bool(tour.get("id")),
    "the person who knows a route is the one who walks it, which in this group "
    "is not necessarily the person holding the coordinator role",
)

status, _ = h.req(
    "POST", "/api/collections/tours/records", guest_token,
    {"org": ORG, "name": "Gastentour", "is_active": True},
)
h.check("a guest cannot", status >= 400, f"status {status}")

status, _ = h.req(
    "POST", "/api/collections/tours/records", member_token,
    {"org": ORG, "name": "tour 1", "is_active": True},
)
h.check(
    "a second route cannot take the same name, differing only in case",
    status >= 400,
    f'status {status} — "Tour 1 fortsetzen" has to mean one thing; two rows '
    'called "Tour 1" make every sentence the app says about a tour ambiguous',
)

status, _ = h.req(
    "DELETE", f"/api/collections/tours/records/{tour['id']}", member_token
)
h.check(
    "a member cannot delete a template",
    status >= 400,
    f"status {status} — deleting one orphans every round ever walked under it; "
    "`is_active = false` keeps both and is the move",
)

# ── The stops, and the two parents that have to be checked ─────────────────

stop_one = h.mk(
    member_token,
    "tour_spots",
    {"org": ORG, "tour": tour["id"], "spot": vhost["id"], "sort_index": 0},
)
h.check("a stop can be added to a route", bool(stop_one.get("id")))
h.check(
    "...with its org taken from the tour, not from the body",
    stop_one.get("org") == ORG,
    str(stop_one.get("org")),
)

status, body = h.req(
    "POST", "/api/collections/tour_spots/records", member_token,
    {"org": ORG, "tour": tour["id"], "spot": foreign_spot["id"]},
)
h.check(
    "a stop cannot point at ANOTHER org's building",
    status >= 400,
    f"status {status} — the rule passes (the body's org is the caller's own); "
    "only a hook can dereference the spot and see whose it is",
)
h.check(
    "...and it is the same code as a spot that does not exist",
    refused_with(body, "tour_stop_spot_not_found"),
    f"{refusal_codes(body)} — a distinct code would tell the caller the id "
    "exists in another organisation",
)

foreign_tour = h.mk(
    T, "tours", {"org": "org00000foreign", "name": "Fremde Tour", "is_active": True}
)
status, body = h.req(
    "POST", "/api/collections/tour_spots/records", member_token,
    {"org": ORG, "tour": foreign_tour["id"], "spot": vhost["id"]},
)
h.check(
    "a stop cannot be hung off ANOTHER org's route",
    status >= 400 and refused_with(body, "tour_not_found"),
    f"status {status}, {refusal_codes(body)} — this is the tenancy SOURCE: "
    "unchecked, the caller's own org in the body plus a foreign tour id moves "
    "the row into the other organisation",
)

status, _ = h.req(
    "POST", "/api/collections/tour_spots/records", member_token,
    {"org": ORG, "tour": tour["id"], "spot": vhost["id"], "sort_index": 5},
)
h.check(
    "the same building cannot be a stop on one route twice",
    status >= 400,
    f'status {status} — it makes progress uncountable ("2 of 7" over six '
    "distinct buildings) and there is no field trip it describes",
)

status, _ = h.req(
    "PATCH", f"/api/collections/tour_spots/records/{stop_one['id']}", member_token,
    {"sort_index": 3},
)
h.check("a stop can be reordered", status == 200, f"status {status}")

status, _ = h.req(
    "PATCH", f"/api/collections/tour_spots/records/{stop_one['id']}", member_token,
    {"spot": other_spot["id"]},
)
h.check(
    "a stop cannot be re-pointed at another building",
    status >= 400,
    f"status {status} — that silently rewrites what a route IS while every "
    "screen keeps showing the same row; remove and re-add is the honest edit",
)

stop_two = h.mk(
    member_token,
    "tour_spots",
    {"org": ORG, "tour": tour["id"], "spot": other_spot["id"], "sort_index": 1},
)
status, _ = h.req(
    "DELETE", f"/api/collections/tour_spots/records/{stop_two['id']}", member_token
)
h.check(
    "a member can take a stop off a route",
    h.ok(status),
    f"status {status} — no visit, no nest and no history hangs off a stop, so "
    "this is ordinary editing",
)

# ── A round: server-owned identity ─────────────────────────────────────────

run = h.mk(
    member_token,
    "tour_runs",
    {
        "org": ORG,
        "tour": tour["id"],
        # Every one of these is a lie the client is allowed to send and the
        # server must not believe.
        "tour_name": "Ganz andere Tour",
        "started_by": coord["id"],
        "started_by_name": "Jemand anders",
        "started_at": "2020-01-01 08:00:00.000Z",
        "finished_at": "2020-01-01 09:00:00.000Z",
    },
)
h.check(
    "the round's name is copied from the template, not from the body",
    run.get("tour_name") == "Tour 1",
    f"{run.get('tour_name')} — a snapshot the client supplies is a snapshot "
    "that can lie in the one direction nobody can catch: the field exists "
    "precisely because the template may be gone",
)
h.check(
    "...it is walked by whoever started it",
    run.get("started_by") == member["id"],
    f"{run.get('started_by')} — 'started by' is a fact about the request",
)
h.check(
    "...it started now, not in 2020",
    not str(run.get("started_at", "")).startswith("2020"),
    f"{run.get('started_at')} — a backdated start puts its visits inside a "
    "window they were not walked in, and Phase 07 counts exactly that window",
)
h.check(
    "...and it begins OPEN",
    not run.get("finished_at"),
    f"{run.get('finished_at')} — a round that was over before it began would "
    "never be offered as 'fortsetzen', which is the whole of avq.4",
)

adhoc = h.mk(member_token, "tour_runs", {"org": ORG, "tour_name": "Erfunden"})
h.check(
    "a round with no template is legal — that IS the ad-hoc mode",
    bool(adhoc.get("id")) and not adhoc.get("tour"),
    "a schema needing a template first would push the three-Spots-on-the-way-"
    "home case out of the app, and somebody then walks it and writes nothing",
)
h.check(
    "...and it carries no name at all",
    adhoc.get("tour_name") == "",
    f"{adhoc.get('tour_name')} — an empty name is how a reader tells "
    "'improvised' from 'the template is gone', which is a different claim",
)

status, body = h.req(
    "POST", "/api/collections/tour_runs/records", member_token,
    {"org": ORG, "tour": foreign_tour["id"]},
)
h.check(
    "a round cannot be walked on ANOTHER org's route",
    status >= 400 and refused_with(body, "tour_not_found"),
    f"status {status}, {refusal_codes(body)}",
)

# ── The visits are the progress ────────────────────────────────────────────

status, body = post_visit(
    member_token,
    {"spot": vhost["id"], "outcome": "checked", "visited_at": h.stamp(),
     "tour_run": run["id"],
     "checks": [{"nest": vn1["id"], "state": "empty"}]},
    key="tour-run-visit-1",
)
h.check("a visit can be recorded as part of a round", status == 200, f"status {status}")
_, walked = h.req(
    "GET", f"/api/collections/visits/records/{(body or {}).get('visit')}", member_token
)
h.check(
    "...and it carries the round",
    (walked or {}).get("tour_run") == run["id"],
    f"{(walked or {}).get('tour_run')} — this relation is the ONLY link between "
    "a tour and the work done on it; there is no per-stop progress row, because "
    "every state one could hold is already this visit",
)

status, _ = h.req(
    "PATCH", f"/api/collections/visits/records/{walked['id']}", member_token,
    {"tour_run": adhoc["id"]},
)
h.check(
    "a recorded visit cannot be moved into another round afterwards",
    status >= 400,
    f"status {status} — it would rewrite what a completed round says was done "
    "on it, and the note is the only thing a visit lets you correct",
)

status, body = post_visit(
    member_token,
    {"spot": vhost["id"], "outcome": "checked", "visited_at": h.stamp(),
     "tour_run": "nonexistent00000", "checks": []},
    key="tour-run-visit-missing",
)
h.check(
    "a visit cannot name a round that does not exist",
    status >= 400 and refused_with(body, "visit_tour_run_not_found"),
    f"status {status}, {refusal_codes(body)}",
)

# ── Finishing, once ────────────────────────────────────────────────────────

status, finished = h.req(
    "PATCH", f"/api/collections/tour_runs/records/{run['id']}", member_token,
    {"finished_at": "2020-01-01 09:00:00.000Z", "note": "Alles abgelaufen"},
)
h.check("a round can be finished", status == 200, f"status {status}")
h.check(
    "...stamped by the server, not by the body",
    status == 200 and not str((finished or {}).get("finished_at", "")).startswith("2020"),
    f"{(finished or {}).get('finished_at')} — the client says THAT it is done, "
    "the server says when",
)
h.check(
    "...and the note it carries is kept",
    (finished or {}).get("note") == "Alles abgelaufen",
    str((finished or {}).get("note")),
)

status, body = h.req(
    "PATCH", f"/api/collections/tour_runs/records/{run['id']}", member_token,
    {"finished_at": None},
)
h.check(
    "a finished round cannot be reopened",
    status >= 400 and refused_with(body, "tour_run_already_finished"),
    f"status {status}, {refusal_codes(body)} — `finished_at` IS the open/closed "
    "state, so blanking it is the one edit no rule can see: a rule reads the "
    "stored row, where the timestamp is still there",
)

status, body = h.req(
    "PATCH", f"/api/collections/tour_runs/records/{run['id']}", member_token,
    {"finished_at": h.stamp()},
)
h.check(
    "...nor re-finished at a different time",
    status >= 400 and refused_with(body, "tour_run_already_finished"),
    f"status {status}, {refusal_codes(body)}",
)

status, body = post_visit(
    member_token,
    {"spot": vhost["id"], "outcome": "checked", "visited_at": h.stamp(),
     "tour_run": run["id"], "checks": []},
    key="tour-run-visit-after-finish",
)
h.check(
    "no visit lands in a round that is already over",
    status >= 400 and refused_with(body, "visit_tour_run_finished"),
    f"status {status}, {refusal_codes(body)} — the round's `finished_at` would "
    "then be earlier than a visit it contains, and it is a STATEMENT about what "
    "was done",
)

status, _ = h.req(
    "PATCH", f"/api/collections/tour_runs/records/{run['id']}", member_token,
    {"tour": None, "started_by": coord["id"]},
)
h.check(
    "a round's identity is pinned after the fact",
    status >= 400,
    f"status {status} — the template, the name, the walker and the start are "
    "what the visits inside it are grouped BY",
)

# ── Discarding an accidental start ─────────────────────────────────────────

mine = h.mk(member_token, "tour_runs", {"org": ORG, "tour": tour["id"]})
status, _ = h.req(
    "DELETE", f"/api/collections/tour_runs/records/{mine['id']}", other_token
)
h.check(
    "one member cannot discard another's open round",
    status >= 400,
    f"status {status}",
)
status, _ = h.req(
    "DELETE", f"/api/collections/tour_runs/records/{mine['id']}", member_token
)
h.check(
    "...but you can discard your OWN, while it is still open",
    h.ok(status),
    f"status {status} — a wrong tap on the dashboard otherwise sits there being "
    "offered as 'fortsetzen' forever",
)

status, _ = h.req(
    "DELETE", f"/api/collections/tour_runs/records/{run['id']}", coord_token
)
h.check(
    "a FINISHED round is history, and not even the coordination deletes one",
    status >= 400,
    f"status {status} — it is what a set of visits was walked as, and those "
    "visits cannot be deleted either",
)

# ── What a round outlives ──────────────────────────────────────────────────

disposable = h.mk(
    coord_token, "tours", {"org": ORG, "name": "Wegwerftour", "is_active": True}
)
disposable_stop = h.mk(
    coord_token,
    "tour_spots",
    {"org": ORG, "tour": disposable["id"], "spot": vhost["id"], "sort_index": 0},
)
disposable_run = h.mk(member_token, "tour_runs", {"org": ORG, "tour": disposable["id"]})
status, body = post_visit(
    member_token,
    {"spot": vhost["id"], "outcome": "skipped", "skip_reason": "no_key",
     "visited_at": h.stamp(), "tour_run": disposable_run["id"]},
    key="tour-run-visit-2",
)
h.check(
    "a skipped Spot is recorded as an ordinary skipped visit in the round",
    status == 200,
    f"status {status} — adding and skipping are equal-rank actions, and here "
    "that is true in the SCHEMA: both write the same row shape",
)
orphan_visit = (body or {}).get("visit")

status, _ = h.req(
    "DELETE", f"/api/collections/tours/records/{disposable['id']}", coord_token
)
h.check("a coordinator can delete a template", h.ok(status), f"status {status}")

status, _ = h.req(
    "GET", f"/api/collections/tour_spots/records/{disposable_stop['id']}", coord_token
)
h.check("...and its stop list goes with it", status >= 400, f"status {status}")

status, survived = h.req(
    "GET", f"/api/collections/tour_runs/records/{disposable_run['id']}", coord_token
)
h.check(
    "...but the round walked under it stands",
    status == 200 and not (survived or {}).get("tour"),
    f"status {status} — a deleted route must not erase last spring's rounds",
)
h.check(
    "...and still says what it was called",
    (survived or {}).get("tour_name") == "Wegwerftour",
    f"{(survived or {}).get('tour_name')} — an id whose target is gone "
    "describes the past wrongly: 'a run of (nothing)'",
)

status, _ = h.req(
    "GET", f"/api/collections/visits/records/{orphan_visit}", coord_token
)
h.check(
    "...and so does the visit made on it",
    status == 200,
    f"status {status} — the visit is the observation this app exists to keep; "
    "the round is only the bag it was carried in",
)


# ── Zahlen: die Statistik und die drei Berichte ─────────────────────────────
#
# eiermann-fi2. What is asserted here is not mainly access control — the sweeps
# and the guest wall already cover who may read `visit_rows`. It is that the
# three documents and the screen AGREE, because that is the property the whole
# phase exists for: a Behörde and a Förderer reading two exports of the same
# period must not find two different numbers, and neither may disagree with the
# app.
#
# The pure period arithmetic is unit-tested next door
# (tests/unit/app_stats_test.js), in milliseconds and rung by rung. What can
# only be tested here is the part that needs a real PocketBase: the view's
# json-typed columns being decoded rather than read as `"4"`, and the year
# boundary holding through the actual filter and the actual bucketing.

print("\n[Statistik und Berichte]")

STATS = "/api/eiermann/stats"
REPORTS = "/api/eiermann/reports/period"

# A building with a full year's worth of work at a known address, so the figures
# below are checked against arithmetic done by hand rather than against whatever
# the endpoint returns.
rhost = h.mk(
    coord_token,
    "spots",
    {"org": ORG, "name": "Berichtshaus", "phase": "active",
     "street": "Mühlenstraße 5", "postal_code": "26121", "city": "Oldenburg"},
)
rarea = h.mk(
    coord_token, "areas", {"org": ORG, "spot": rhost["id"], "name": "Dachboden"}
)


def rnest(label):
    return h.mk(
        coord_token,
        "nests",
        {"org": ORG, "area": rarea["id"], "label": label,
         "species": "feral_pigeon", "status": "active"},
    )


rn1 = rnest("R1")
rn2 = rnest("R2")

# Two eggs swapped in one nest, the other found empty, plus a dead pigeon on the
# floor. One visit, hand-countable: 1 swapped, 1 empty, 2 removed, 2 placed,
# 1 finding.
status, _ = post_visit(
    member_token,
    {
        "spot": rhost["id"],
        "visited_at": h.stamp(days=-2),
        "outcome": "checked",
        "checks": [
            {"nest": rn1["id"], "state": "swapped", "real_before": 2,
             "dummy_before": 0, "removed_real": 2, "added_dummy": 2,
             "real_after": 0, "dummy_after": 2},
            {"nest": rn2["id"], "state": "empty", "real_before": 0,
             "dummy_before": 0, "real_after": 0, "dummy_after": 0},
        ],
        "findings": [
            {"kind": "dead_bird", "count": 1, "species_label": "Dohle"},
        ],
    },
    key="report-visit-1",
)
h.check("a visit to report on was written", status == 200, f"status {status}")

# And a trip where nobody was home. A document, not an observation — and the
# figure a request for a key is argued with, so it has to survive into the
# report rather than being filtered out as "nothing happened".
status, _ = post_visit(
    member_token,
    {
        "spot": rhost["id"],
        "visited_at": h.stamp(days=-1),
        "outcome": "skipped",
        "skip_reason": "no_key",
    },
    key="report-visit-2",
)
h.check("...and a trip where nobody was home", status == 200, f"status {status}")

# ── The view ───────────────────────────────────────────────────────────────
_, vr = h.req(
    "GET",
    "/api/collections/visit_rows/records?filter="
    + urllib.parse.quote(f"spot='{rhost['id']}'")
    + "&sort=visited_at",
    member_token,
)
vr_items = (vr or {}).get("items") or []
h.check(
    "visit_rows carries the address and the per-visit numbers in one row",
    len(vr_items) == 2,
    f"{vr} — the report table is defined once, and all three exports read it",
)
if len(vr_items) == 2:
    first, second = vr_items
    h.check(
        "...the address comes from the Spot, so the report needs no join",
        first.get("street") == "Mühlenstraße 5"
        and first.get("postal_code") == "26121"
        and first.get("city") == "Oldenburg",
        str(first),
    )
    h.check(
        "...the check census reconciles with checks_total",
        first.get("checks_total") == 2
        and first.get("swapped_count") == 1
        and first.get("empty_count") == 1
        and sum(
            first.get(k, 0)
            for k in ("swapped_count", "partial_count", "empty_count",
                      "untouched_count", "not_reachable_count", "gone_count",
                      "protected_count")
        )
        == first.get("checks_total"),
        f"{first} — a census that does not add up is a line a Behörde asks "
        "about, because the missing checks look like the interesting ones",
    )
    h.check(
        "...the egg sums are NUMBERS, not quoted JSON",
        first.get("removed_real") == 2 and first.get("added_dummy") == 2,
        f"{first} — a computed view column falls back to type json, and a "
        'server-side reader gets `"2"` with the quotes; if that were left '
        "undecoded every count in every report would be NaN",
    )
    h.check(
        "...the findings of the trip arrive joined, by wire kind",
        first.get("findings_total") == 1
        and first.get("findings_text") == "dead_bird",
        f"{first} — German would be untranslatable by construction: the server "
        "does not know which language the reader speaks",
    )
    h.check(
        "...and the skipped trip keeps its row, with its reason and zeros",
        second.get("outcome") == "skipped"
        and second.get("skip_reason") == "no_key"
        and second.get("checks_total") == 0
        and second.get("removed_real") == 0,
        f"{second} — filtering it out would claim the building was never "
        "visited, which is the opposite of what the volunteer recorded",
    )

# ── Access ─────────────────────────────────────────────────────────────────
# `req_bytes` and not `req` throughout: a route that WRONGLY lets one of these
# callers through answers with a PDF, and `req` decodes the body as UTF-8 — so
# the suite would die on a traceback instead of reporting the leak. A guard that
# crashes on the failure it exists to catch reports nothing.
for path in (STATS, REPORTS):
    status, _, _ = h.req_bytes("GET", path, None)
    h.check(f"{path} refuses an anonymous caller", status == 401, f"status {status}")
    status, _, _ = h.req_bytes("GET", path, roleless_token)
    h.check(
        f"...and a role-less account on {path}",
        status >= 400,
        f"status {status} — a custom route does not inherit the clause every "
        "access rule opens with",
    )
    status, _, _ = h.req_bytes("GET", path, guest_token)
    h.check(
        f"...and a guest on {path}",
        status >= 400,
        f"status {status} — `guest` is a non-null role, so a route that checks "
        "only for one is the guest wall not applying to the export that carries "
        "every address the org holds",
    )

# ── The statistics screen, in one response ─────────────────────────────────
_, stats = h.req("GET", f"{STATS}?tzOffsetMinutes=60", member_token)
h.check(
    "the whole statistics screen arrives in one call",
    isinstance(stats, dict)
    and {"period", "totals", "series", "checkStates", "findingKinds",
         "findingSpecies", "skipReasons", "addresses", "visitYears",
         "spots"} <= set(stats),
    f"{stats} — the client aggregates NOTHING; the alternative is pulling "
    "visits, checks and findings unpaginated to the device and putting a second "
    "definition of every figure in the app",
)
if isinstance(stats, dict) and "totals" in stats:
    totals = stats["totals"]
    h.check(
        "...the numbers are numbers",
        isinstance(totals.get("removedReal"), int)
        and isinstance(totals.get("visits"), int),
        f"{totals}",
    )
    h.check(
        "...and every value stays a WIRE value",
        all(s["state"] in {"swapped", "partial", "empty", "untouched",
                           "not_reachable", "gone", "protected"}
            for s in stats["checkStates"]),
        f"{stats['checkStates']} — a hook never sends user-facing text",
    )
    h.check(
        "...the check-state census is complete and in the enum's order",
        [s["state"] for s in stats["checkStates"]]
        == ["swapped", "partial", "empty", "untouched", "not_reachable",
            "gone", "protected"],
        f"{stats['checkStates']} — a reader compares this against the same "
        "order in every export",
    )
    h.check(
        "...the standing Spot figures are there, and are not period-scoped",
        stats["spots"]["total"] > 0
        and all("phase" in p for p in stats["spots"]["phases"]),
        f"{stats['spots']} — 'how many buildings do we have access to' has "
        "nothing to do with ?year=, and narrowing it would change a number "
        "that did not change",
    )

# A garbled period is refused rather than reported on: a confidently empty
# report looks like an answer.
for query in ("year=letztes", "year=26", "month=3", "year=2026&month=13"):
    status, _ = h.req("GET", f"{STATS}?{query}", member_token)
    h.check(
        f"the period ?{query} is refused, not silently reported on",
        status == 400,
        f"status {status}",
    )
status, _ = h.req("GET", f"{REPORTS}?format=xlsx", member_token)
h.check("an unknown format is refused", status == 400, f"status {status}")

# ── THE YEAR BOUNDARY, in both documents at once ───────────────────────────
#
# eiermann-fi2.8. The report SELECTS rows with `visited_at >= from && < to`; the
# statistics route reads everything and buckets on the caller's local year. If
# those two resolve the boundary differently, a New Year's Eve visit is in the
# report and missing from the chart — or counted in both years, and then two
# consecutive documents cannot be added up.
#
# A visit stamped 23:30 UTC on 31 December is 00:30 on 1 January for a caller at
# +60, so BOTH have to call it the new year. Written through the real endpoint,
# read back through the real filter: the unit test proves the arithmetic, this
# proves the two consumers actually share it.
BOUNDARY_YEAR = 2031  # comfortably in the future, so nothing else counts here
nyhost = h.mk(
    coord_token,
    "spots",
    {"org": ORG, "name": "Silvesterhaus", "phase": "active",
     "street": "Am Jahreswechsel 1", "city": "Oldenburg"},
)
status, _ = post_visit(
    member_token,
    {
        "spot": nyhost["id"],
        "visited_at": f"{BOUNDARY_YEAR - 1}-12-31 23:30:00.000Z",
        "outcome": "checked",
        "checks": [],
    },
    key="new-years-eve",
)
h.check("a visit at 23:30 UTC on New Year's Eve was written", status == 200,
        f"status {status}")

_, ny_stats = h.req(
    "GET", f"{STATS}?year={BOUNDARY_YEAR}&tzOffsetMinutes=60", member_token
)
_, ny_prev = h.req(
    "GET", f"{STATS}?year={BOUNDARY_YEAR - 1}&tzOffsetMinutes=60", member_token
)
h.check(
    "the statistics screen puts it in the caller's year, not UTC's",
    (ny_stats or {}).get("totals", {}).get("visits") == 1
    and (ny_prev or {}).get("totals", {}).get("visits") == 0,
    f"{BOUNDARY_YEAR}: {(ny_stats or {}).get('totals')} / "
    f"{BOUNDARY_YEAR - 1}: {(ny_prev or {}).get('totals')} — in CET everything "
    "after 23:00 UTC belongs to the next day, and that is invisible on a UTC "
    "CI machine",
)
h.check(
    "...and offers the year in its picker",
    BOUNDARY_YEAR in ((ny_stats or {}).get("visitYears") or []),
    str((ny_stats or {}).get("visitYears")),
)

status, csv_bytes, headers = h.req_bytes(
    "GET",
    f"{REPORTS}?format=csv&year={BOUNDARY_YEAR}&tzOffsetMinutes=60",
    member_token,
)
csv_text = csv_bytes.decode("utf-8-sig")
h.check(
    "the CSV of the same year contains exactly the same visit",
    h.ok(status) and csv_text.count("Am Jahreswechsel 1") == 1,
    f"status {status}: {csv_text[:400]} — the report filters on an instant "
    "range while the screen buckets on a local year; if those disagree the two "
    "documents cannot be added up",
)
status, empty_csv, _ = h.req_bytes(
    "GET",
    f"{REPORTS}?format=csv&year={BOUNDARY_YEAR - 1}&tzOffsetMinutes=60",
    member_token,
)
h.check(
    "...and the previous year's does not",
    h.ok(status) and "Am Jahreswechsel 1" not in empty_csv.decode("utf-8-sig"),
    empty_csv.decode("utf-8-sig")[:200],
)

# ── The CSV ────────────────────────────────────────────────────────────────
status, csv_bytes, headers = h.req_bytes(
    f"GET", f"{REPORTS}?format=csv&tzOffsetMinutes=60", member_token
)
csv_text = csv_bytes.decode("utf-8-sig")
h.check(
    "the CSV is served as an attachment with a sortable ASCII name",
    h.ok(status)
    and "eiermann-bericht-gesamt.csv" in (headers.get("Content-Disposition") or ""),
    f"status {status}, {headers.get('Content-Disposition')} — a filename with an "
    "umlaut in it arrives mangled or dropped depending on the client",
)
h.check(
    "...and begins with the UTF-8 BOM a spreadsheet needs",
    csv_bytes[:3] == b"\xef\xbb\xbf",
    str(csv_bytes[:8]) + " — without it Excel reads Mühlenstraße as mojibake, "
    "and it is only visible in the finished spreadsheet",
)
h.check(
    "...with CRLF line endings, per RFC 4180",
    b"\r\n" in csv_bytes,
    str(csv_bytes[:120]),
)
h.check(
    "...its column titles come from shared_strings.json, in German",
    "Nester geprüft" in csv_text and "Eier entnommen" in csv_text,
    csv_text.splitlines()[0] if csv_text else "empty"
    + " — the CSV has no template layer to translate in, so it reads the same "
    "file the Typst templates merge",
)
h.check(
    "...and its cells are labels, not wire values",
    "Kein Schlüssel" in csv_text and "Totfund" in csv_text,
    csv_text[:600],
)
h.check(
    "...the English half resolves too",
    "Nests checked"
    in h.req_bytes(f"GET", f"{REPORTS}?format=csv&lang=en", member_token)[1].decode(
        "utf-8-sig"
    ),
    "?lang=en is a supported parameter, and a document that falls back to "
    "German for half its strings is what the two-file mechanism exists to "
    "prevent",
)

# THE FORMULA GUARD. Every one of these cells is user-authored, and
# Excel/LibreOffice EXECUTE a cell that begins with =, +, -, @, tab or CR. RFC
# 4180 quoting does not prevent it: the quotes are stripped before the formula
# parser sees the cell.
evil = h.mk(
    coord_token,
    "spots",
    {"org": ORG, "name": "=HYPERLINK(\"http://evil.example\",\"klick\")",
     "phase": "active", "street": "=1+1", "city": "@SUM(A1:A9)"},
)
status, _ = post_visit(
    member_token,
    {
        "spot": evil["id"],
        "visited_at": h.stamp(days=-1),
        "outcome": "skipped",
        "skip_reason": "other",
        "skip_note": "-2+3",
        "note": "+49 441 123456",
    },
    key="formula-guard",
)
h.check("a visit at a formula-shaped address was written", status == 200,
        f"status {status}")
status, evil_bytes, _ = h.req_bytes(f"GET", f"{REPORTS}?format=csv", member_token)
evil_csv = evil_bytes.decode("utf-8-sig")
h.check(
    "a formula-shaped cell is neutralised with a leading apostrophe",
    "'=1+1" in evil_csv
    and "'@SUM(A1:A9)" in evil_csv
    and "'+49 441 123456" in evil_csv,
    evil_csv[-700:] + " — OWASP CSV Injection: the street, the city, the Spot "
    "name and the note are all typed by volunteers, and one of them opening a "
    "spreadsheet is all this needs",
)
h.check(
    "...and no cell in the whole export starts a formula",
    not any(
        cell.lstrip('"').startswith(("=", "+", "@"))
        for line in evil_csv.splitlines()
        for cell in line.split(",")
    ),
    evil_csv[-700:],
)

# ── The PDFs ───────────────────────────────────────────────────────────────
for fmt, name in (
    ("pdf", "eiermann-bericht-gesamt.pdf"),
    ("summary", "eiermann-uebersicht-gesamt.pdf"),
):
    status, body, headers = h.req_bytes(
        f"GET", f"{REPORTS}?format={fmt}&tzOffsetMinutes=60", member_token
    )
    h.check(
        f"?format={fmt} renders a PDF",
        h.ok(status) and body[:5] == b"%PDF-",
        f"status {status}, {body[:60]!r} — a Typst compile that fails answers "
        "500 with a log line, never a truncated file",
    )
    h.check(
        f"...named {name}",
        name in (headers.get("Content-Disposition") or ""),
        str(headers.get("Content-Disposition")),
    )
    h.check(
        f"...and typed as one",
        (headers.get("Content-Type") or "").startswith("application/pdf"),
        str(headers.get("Content-Type")),
    )

# A period with nothing in it still renders: the template says so on the page
# rather than printing a document full of noughts, and an empty export must not
# be a 500 the caller cannot distinguish from a broken renderer.
status, body, _ = h.req_bytes(
    f"GET", f"{REPORTS}?year=1999&tzOffsetMinutes=60", member_token
)
h.check(
    "a period with no visits renders a document, not an error",
    h.ok(status) and body[:5] == b"%PDF-",
    f"status {status}, {body[:60]!r}",
)


# ── The delete-effect registry ─────────────────────────────────────────────
#
# A cascading delete does not LEAVE a forgotten collection behind. It DESTROYS
# its rows, and answers 200. Adding `nest_checks` in Phase 04 without noticing
# that `nests` cascades from `spots` means one coordinator tap silently erases
# every check ever recorded — and the response says success.
#
# So every relation that cascades is written down here with what it takes with
# it, and the sweep fails in BOTH directions:
#
#   * a cascade with no entry — somebody added a relation and did not think
#     about what deleting the parent destroys;
#   * an entry with no cascade — the registry claims a cascade that is not
#     there, so a reader trusts a guarantee nothing enforces.
#
# One-directional would be worse than nothing: it would let the registry drift
# into fiction while still passing.

print("\n[delete-effect registry]")

# collection.field -> what deleting the PARENT row destroys.
# Read the `spots.*` rows together before touching any of them. Deleting ONE
# Spot now destroys, in one 200: its Bereiche and their photos, every nest,
# every check ever recorded on those nests, the current egg state, every visit
# to the building, every finding, every photo that belonged to no nest, and
# every outstanding Nachkontrolle. That is the entire memory of a building.
#
# Which is the argument for `phase = closed`, and why deleting is
# coordinator-only: closing keeps all of it. If the list below ever looks
# alarming, that is the list working.
DELETE_EFFECTS = {
    "areas.spot": "the Bereich, its photo, and every nest in it",
    "spot_contacts.spot": "the caretaker's name and phone number (this IS the "
                          "retention policy — there is no scrub cron)",
    "nests.spot": "every nest in the building, and its whole check history",
    "nests.area": "every nest pinned on that Bereich's photo",
    "visits.spot": "every visit ever made to the building",
    "visit_photos.visit": "the door, the new lock, the scaffolding",
    "nest_checks.visit": "what was found on that trip",
    "nest_checks.nest": "the nest's whole history — the answer to 'what was in "
                        "here in April'",
    "nest_eggs.nest": "the current egg state; derived, so this one is "
                      "recoverable in principle and the checks above are not",
    "findings.visit": "the dead birds, chicks and structural changes recorded "
                      "on that trip",
    "findings.spot": "the same, reached the other way — findings are "
                     "denormalised onto the Spot",
    "findings.nest": "a finding attached to a nest goes when the nest goes",
    "follow_ups.spot": "outstanding Nachkontrollen for the building",
    "follow_ups.nest": "the Halbgelege follow-up for that nest",
    "tour_spots.tour": "the route's ordered stop list",
    # Read this one next to the `spots.*` block above. It is the only thing
    # deleting a Spot destroys that is NOT part of that building's own memory:
    # a route somebody else walks loses a stop.
    "tour_spots.spot": "the building's place on every route it was a stop on",
}

# Relations that deliberately do NOT cascade, with the reason. Listed so that
# turning one into a cascade is a visible change and not a quiet default.
NO_CASCADE = {
    "areas.org": "an organisation is never deleted; deactivating it is the move",
    "nests.org": "same",
    "spots.org": "same",
    "spot_contacts.org": "same",
    "users.org": "same",
    # This one is worth reading twice. If `invited_by` ever cascaded, deleting
    # one coordinator would delete every person they onboarded — the whole team,
    # from one tap, with a 200. The absence of a cascade here is a decision, and
    # that is why it is written down rather than left as a default.
    "users.invited_by": "deleting an inviter must never delete the people they "
                        "invited — that would take out the whole team from one "
                        "coordinator's account",
    "visits.org": "same",
    "visit_photos.org": "same",
    "nest_checks.org": "same",
    "nest_eggs.org": "same",
    "findings.org": "same",
    "follow_ups.org": "same",
    # An author is a relation to an account, and an account CAN be deleted. It
    # must not take the record with it: a visit somebody made still happened
    # after they leave, and the history has to stand. This is why every
    # audit-shaped row also stores `author_name` — an id whose target is gone
    # tells the past wrongly, and a relation without a snapshot beside it is a
    # bug.
    "visits.author": "a deleted account must not erase the visits it recorded",
    "nest_checks.author": "same — the check stands, `author_name` carries who",
    "findings.author": "same",
    # A check is immutable and nothing can delete one, so these never fire. They
    # are non-cascading deliberately rather than by default, so that a future
    # cascade on checks cannot silently reach into the follow-ups and the eggs.
    "nest_eggs.source_check": "checks are immutable; a cascade here would be a "
                              "path that must not come to exist",
    "follow_ups.created_from_check": "same — the Nachkontrolle outlives the "
                                     "check that caused it",
    "follow_ups.resolved_by_check": "same",
    "tours.org": "same",
    "tour_spots.org": "same",
    "tour_runs.org": "same",
    # A run is history: it happened, on a day, walked by somebody. Neither the
    # template it followed nor the account that walked it may take it with them
    # — which is why the run stores `tour_name` and `started_by_name` beside
    # both ids. An id whose target is gone describes the past wrongly.
    "tour_runs.tour": "a retired or deleted route must not erase the rounds "
                      "walked under it; `tour_name` carries what it was called",
    "tour_runs.started_by": "a deleted account must not erase the rounds it "
                            "walked",
    # The visit is the observation this app exists to keep; the run is only the
    # bag it was carried in. Discarding an accidentally started run must not
    # take real field work with it.
    "visits.tour_run": "deleting a round must never delete the visits made "
                       "during it",
}

schema = h.collections(T)
actual_cascades = set()
actual_relations = set()
for collection in schema:
    # A view has no rows of its own, so it deletes nothing: its relation columns
    # are projections of the underlying table's. Classifying them would mean
    # re-stating every source table's decision in a second place, where the two
    # copies could disagree.
    if collection.get("type") == "view":
        continue
    for field in collection.get("fields") or []:
        if field.get("type") != "relation":
            continue
        key = f"{collection['name']}.{field['name']}"
        actual_relations.add(key)
        if field.get("cascadeDelete"):
            actual_cascades.add(key)

# Only the collections this suite governs; PocketBase's own system collections
# have their own relations and are not ours to document.
system = {c["name"] for c in schema if str(c["name"]).startswith("_")}
actual_cascades = {k for k in actual_cascades if k.split(".")[0] not in system}
actual_relations = {k for k in actual_relations if k.split(".")[0] not in system}

undocumented = sorted(actual_cascades - set(DELETE_EFFECTS))
h.check(
    "every cascading relation is in the registry",
    not undocumented,
    f"{undocumented} — a cascade nobody wrote down is data that disappears on "
    "a 200",
)

fictional = sorted(set(DELETE_EFFECTS) - actual_cascades)
h.check(
    "every registry entry is a real cascade",
    not fictional,
    f"{fictional} — the registry would be claiming a guarantee nothing "
    "enforces, which is worse than an empty registry",
)

unaccounted = sorted(
    actual_relations - set(DELETE_EFFECTS) - set(NO_CASCADE)
)
h.check(
    "every relation is accounted for, cascade or not",
    not unaccounted,
    f"{unaccounted} — add it to DELETE_EFFECTS or to NO_CASCADE with the "
    "reason; a relation nobody classified is the next silent cascade",
)

h.check(
    "...and the registry is not empty",
    len(DELETE_EFFECTS) >= 4,
    "an empty registry passes every check above while documenting nothing",
)

# Not just declared — observed. A cascade that is configured but does not fire
# (or fires further than the registry says) is the same defect as a missing
# entry.
doomed_spot = h.mk(
    coord_token, "spots", {"org": ORG, "name": "Kaskadentest", "phase": "active"}
)
doomed_area = h.mk(
    coord_token,
    "areas",
    {"org": ORG, "spot": doomed_spot["id"], "name": "Zum Löschen"},
)
doomed_nest = h.mk(
    coord_token,
    "nests",
    {"org": ORG, "area": doomed_area["id"], "label": "N1",
     "species": "unknown", "status": "active"},
)
survivor = h.mk(
    coord_token,
    "areas",
    {"org": ORG, "spot": host["id"], "name": "Überlebt"},
)

status, _ = h.req(
    "DELETE", f"/api/collections/spots/records/{doomed_spot['id']}", coord_token
)
h.check("deleting the Spot succeeds", h.ok(status), f"status {status}")

status, _ = h.req(
    "GET", f"/api/collections/areas/records/{doomed_area['id']}", coord_token
)
h.check("...and its Bereich is gone", status >= 400, f"status {status}")

status, _ = h.req(
    "GET", f"/api/collections/nests/records/{doomed_nest['id']}", coord_token
)
h.check(
    "...and the nest with it, though nothing can delete a nest DIRECTLY",
    status >= 400,
    f"status {status} — the cascade is the one path that destroys a nest, which "
    "is exactly why it has to be written down",
)

status, _ = h.req(
    "GET", f"/api/collections/areas/records/{survivor['id']}", coord_token
)
h.check(
    "...and another building's Bereich is untouched",
    status == 200,
    f"status {status} — a cascade that reaches further than the registry says "
    "is the same defect as one nobody wrote down",
)


# ── The shared hooks' own behaviour ────────────────────────────────────────
#
# These assertions are zugvogel's (zv_shared_assertions.py), run here against
# this app's instance. They were absent entirely until now: eiermann mounts
# zv_web_headers and asserted nothing about it, which means the CSP that makes
# the web build work at all — and that blocks the font download which otherwise
# produces an endless console error stream — was untested in the app that ships
# it. federfall had fifteen assertions on the same library.
#
# What is stated here rather than there is what differs: where this app's
# uploaded files live. The map values the derivation looks for are the ones
# run.sh puts in the environment, which both harnesses set identically.

print("\n[shared hooks: rate limits]")

# The assertions are zugvogel's; the label is this app's. Naming it here is the
# point: the geocode proxy hits an upstream with a usage policy, and a budget
# silently not applied is invisible otherwise.
#
# Safe to run here and not earlier: it deliberately trips PocketBase's `*:auth`
# brake, and every login this suite needs happened during fixture setup. The
# brake's window is three seconds, so nothing after it is affected.
shared_assertions.rate_limits(
    h.check,
    h.req,
    T,
    "eiermann",
    [
        "GET /api/eiermann/geocode",
        "GET /api/eiermann/geocode/",
        # eiermann-fi2.6 — the report route spawns a `typst compile` per request.
        # One process per request is what makes a flood expensive for the SERVER
        # rather than for the caller, so a missing budget here is not a policy
        # nicety.
        "GET /api/eiermann/reports/period",
        "GET /api/eiermann/reports/period/",
    ],
)


print("\n[shared hooks: web headers]")

shared_assertions.web_headers(
    h.check,
    h.base,
    files_path=f"/api/files/spots/{host['id']}/nonexistent.png",
)


# ── Sweeps: the properties that must hold for collections not written yet ───

# ── The guest wall, over a database that HAS rows ───────────────────────────
#
# The read half of the guest wall runs HERE, at the end, and that placement is
# the assertion. `h.reads_nothing` checks that no items came back — which an
# EMPTY collection satisfies whatever its rules say. Run beside the sign-in
# check near the top of this file, twelve of these passed over a database that
# had no Spots, no areas and no nests in it yet; the canary that put the old
# `role != null` clause back could only fail two of them. By this point the
# suite has filled every collection above, so a leak has something to leak.
# Every collection a member may read. `role != null` — the clause before
# migration 014 — is satisfied by `guest`, so on the day the role became
# storable each of these would have opened up. This is the list that proves it
# did not.
for collection in (
    "users",
    "organisations",
    "spots",
    "spot_contacts",
    "spot_overview",
    "areas",
    "nests",
    "visits",
    "nest_checks",
    "nest_eggs",
    "findings",
    "follow_ups",
    "nest_state",
    "species_labels",
    "visit_rows",
    "tours",
    "tour_spots",
    "tour_runs",
):
    h.check(
        f"a guest reads nothing from {collection}",
        h.reads_nothing(collection, guest_token),
        "a 200 with rows in it is the leak — a list is filtered, not refused",
    )


print("\n[sweeps over the live schema]")
cols = h.collections(T)
h.check("the schema lists collections at all", bool(cols))

# users and organisations have their own bespoke rules asserted above;
# the two infrastructure tables are deliberately opaque. Everything ELSE has to
# satisfy the sweeps — including collections nobody has written yet, which is
# the entire point of expressing these as sweeps.
DOMAIN_EXEMPT = {"users", "organisations", "geocode_cache", "idempotency_keys"}


# The two shapes a rule's role clause may take. Anything else is a rule that
# lets `guest` — the wall a self-registered account lands behind — through.
ROLE_ALLOWLIST = (
    '(@request.auth.role = "member" || @request.auth.role = "coordinator")'
)
COORDINATOR_ONLY = '@request.auth.role = "coordinator"'


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
        # The role clause is an ALLOWLIST since migration 014, and that is the
        # half a sweep has to carry forward: `role != null` is satisfied by
        # `guest`, the role a self-registered OAuth2 account lands in. A
        # collection written next month that copies the OLD clause would hand
        # every stranger at the identity provider member-level read access, and
        # no per-collection test covers a collection nobody has written yet.
        if COORDINATOR_ONLY not in rule and ROLE_ALLOWLIST not in rule:
            problems.append(f"{kind} does not name the roles that may pass")
    return "; ".join(problems)


sweep_collections(
    h,
    cols,
    "every domain rule requires an authenticated, active caller",
    every_rule_is_gated,
)

# The sweep above cannot see a VIEW: the shared harness selects `type == "base"`,
# because every other sweep it drives asks about writes. So views — the one place
# where the gate is most likely to be missing, since a view does NOT inherit the
# rules of the tables under it — were swept by nothing at all.
#
# This is not hypothetical. `visit_rows` (1700000017) was first written with the
# pre-014 clause `role != null`, which `guest` satisfies: a window onto every
# visit the org had ever recorded, for any stranger the identity provider
# happened to authenticate. The hand-kept guest-wall list above would have caught
# it only because somebody remembered to add the new name to it, which is exactly
# the fragility a sweep exists to remove.
view_offenders = []
for col in cols:
    if col.get("type") != "view":
        continue
    reason = every_rule_is_gated(col)
    if reason:
        view_offenders.append(f"{col['name']}: {reason}")
h.check(
    "every VIEW states the gate itself, since it inherits none",
    not view_offenders,
    "; ".join(view_offenders)
    + " — a view over a carefully scoped table is a second door onto it",
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
