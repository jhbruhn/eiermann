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
# the day it was added — but never overdue on that day: painting every new
# building red is how a colour stops being read. Rank 2 is "due within a week",
# which for a base interval of 7 days is exactly where day one lands.
#
# The view's rank-3 branch for an active Spot with an EMPTY next_due_at is not
# asserted here, because since the create hook derives the date it can no longer
# be reached through the API. It stays in the view as the defensive answer for a
# row that somehow has no date: reading a missing date as urgent would be worse.
fresh_active = h.mk(
    coord_token, "spots", {"org": ORG, "name": "Neu, noch kein Nest", "phase": "active"}
)
h.check(
    "a Spot created active is due inside its first rhythm, and NOT overdue",
    urgency_of(fresh_active["id"]) == 2,
    f"urgency {urgency_of(fresh_active['id'])} — a building nobody has looked "
    "at properly must surface, without being red on the day it was added",
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
# The message is a fallback for whoever sees the raw error, so it has to be
# German — and it has to be German ALL THE WAY. The wire value belongs in the
# structured data, where the client can translate it.
message = str((body or {}).get("message") or "")
h.check(
    "the refusal message is German and self-sufficient",
    "Erlaubt" in message,
    f"{message!r} — and it names the stage with the SAME word the client puts "
    "on it, or the reader goes looking through the Erkundung for a word that "
    "is not there",
)
h.check(
    "...and carries no wire value in its prose",
    not any(wire in message for wire in
            ("untouched", "tenant_spoken", "owner_spoken", "permitted", "refused")),
    f"{message!r} — a sentence half in each language is what keeping the "
    "vocabulary in the client is meant to prevent",
)
# Not asserted: the wire value riding along in the error's `data`. PocketBase
# coerces every leaf of an ApiError's data into `{code, message}` at any depth,
# so that channel is structurally a field-name → validation-error map and
# cannot carry a value. The client holds the record it just tried to update, so
# it already knows the stage.

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
    "...and the refusal does not reveal that the id exists elsewhere",
    "existiert nicht" in str(body),
    str(body)[:160],
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
    "...and the refusal names the law, not just a permission",
    "§44" in str(body),
    str(body)[:200],
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
h.check("...naming the law", "§44" in str(body), str(body)[:200])
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
