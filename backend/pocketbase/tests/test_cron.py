#!/usr/bin/env python3
"""eiermann-gb1 / jbk.15 — the crons, observed actually running.

Driven by run_cron.sh, which rewrites the schedule to every minute. Nothing an
HTTP request can do triggers a `cronAdd` job, so without this suite the job
could be wrong indefinitely and every rule assertion would stay green.

What is asserted is the OUTCOME of a real run, not a simulation of one: a Spot
whose `paused_until` has passed comes back to `active`, with the pause fields
cleared and a fresh due date; an organisation that opted out keeps its Spot
paused; an expired geocode cache row disappears while a live one stays. A test
that called the handlers directly would prove the functions work and say nothing
about whether they are wired to a schedule at all.
"""

import os
import sys
import time

from zv_harness import H

ORG = "org00000default"

h = H()
T = h.admin_token()

COORD_EMAIL = os.environ.get("EIERMANN_COORD_EMAIL", "coordinator@eiermann.local")
COORD_PASS = os.environ.get("EIERMANN_COORD_PASS", "CoordPass12345!")
status, coord_token = h.login(COORD_EMAIL, COORD_PASS)
if not coord_token:
    # `login` answers (status, token) and backs off on the auth rate limit. An
    # empty token would read as anonymous from here on, and an anonymous LIST
    # returns 200 with zero rows — every assertion below would "pass".
    h.fatal(f"could not sign in as the coordinator: {status}")


def paused_spot(name, until_days_ago=2, org=ORG, token=None):
    """A Spot that has been paused with a `paused_until` in the past.

    [token] defaults to the coordinator. The opted-out organisation's Spot is
    made with the SUPERUSER instead, because the coordinator cannot create a
    Spot there and should not be able to: `createRule` pins the body's org to
    the caller's own, so a cross-tenant create is refused — which it duly was,
    the first time this suite tried it.
    """
    token = token or coord_token
    spot = h.mk(token, "spots", {"org": org, "name": name, "phase": "active"})
    status, body = h.req(
        "PATCH",
        f"/api/collections/spots/records/{spot['id']}",
        token,
        {
            "phase": "paused",
            "pause_reason": "Gerüst",
            "paused_until": h.stamp(days=-until_days_ago),
        },
    )
    if status != 200:
        print(f"FATAL: could not pause {name}: {status} {body}", file=sys.stderr)
        sys.exit(1)
    return body


def spot_now(spot_id):
    # Read as the superuser: one of these Spots lives in another organisation,
    # and the coordinator cannot see it — a 404 there would look exactly like a
    # Spot that never resumed.
    _, body = h.req("GET", f"/api/collections/spots/records/{spot_id}", T)
    return body or {}


def wait_for_phase(spot_id, phase, seconds=100):
    """Polls until [spot_id] reaches [phase], or the budget runs out.

    Generous, and deliberately so: the schedule is every minute, so a run can be
    up to a full minute away plus however long it takes. A tight budget here
    produces a flaky suite, and a flaky suite is one nobody reads.
    """
    deadline = time.time() + seconds
    while time.time() < deadline:
        if str(spot_now(spot_id).get("phase")) == phase:
            return True
        time.sleep(2)
    return False


print("[auto-resume]")

# The opted-out organisation. Its own org, because the setting is per-org and a
# second Spot in the same one would prove nothing.
h.mk(
    T,
    "organisations",
    {
        "id": "org00000manuell",
        "name": "Pausen von Hand",
        "is_active": True,
        "settings": {"pause_auto_resume": False},
    },
)

due = paused_spot("Gerüst ist weg")
still_waiting = paused_spot("Gerüst bleibt", until_days_ago=-30)
opted_out = paused_spot("Von Hand", org="org00000manuell", token=T)

h.check("the fixtures start paused", spot_now(due["id"]).get("phase") == "paused")

h.check(
    "a Spot whose paused_until has passed comes back by itself",
    wait_for_phase(due["id"], "active"),
    f"still {spot_now(due['id']).get('phase')} after the wait — the job either "
    "did not run or did not pick it up",
)

resumed = spot_now(due["id"])
h.check(
    "...with the pause fields cleared",
    not resumed.get("pause_reason") and not resumed.get("paused_until"),
    f"pause_reason={resumed.get('pause_reason')!r} "
    f"paused_until={resumed.get('paused_until')!r} — these are current state, "
    "and a resumed Spot still showing 'wegen Gerüst' reads as still paused",
)
h.check(
    "...and a due date, so it is actually back in the lists",
    bool(resumed.get("next_due_at")),
    "a resumed Spot with no due date is invisible everywhere, which is the same "
    "outcome as still being paused",
)

# ── The audit row, which is the only explanation there will ever be ────────
#
# eiermann-30w.6. A Spot leaving a pause with NOBODY near the decision is what
# `actor_kind` exists to say. Without the row a building simply reappears on the
# due list: the record keeps only its current phase, and the coordinator who
# paused it did not do this.
auto = h.listf(
    coord_token,
    "audit_events",
    f"action = 'spot.auto_resumed' && subject_id = '{due['id']}'",
)
h.check(
    "the auto-resume explains itself in the log",
    len(auto) == 1,
    f"{len(auto)} rows",
)
h.check(
    "...as the cron, not as a person and not as a bare 'system'",
    auto and auto[0].get("actor_kind") == "cron",
    f"actor_kind={auto[0].get('actor_kind')!r} — there is no request here, no "
    "caller and no request id, and a row that cannot say so is a row that "
    "implicates whoever looks like the last actor"
    if auto
    else "no row",
)
h.check(
    "...naming the building and the move it made",
    auto
    and auto[0].get("spot_id") == due["id"]
    and "paused" in str(auto[0].get("detail")),
    f"{auto[0].get('detail')!r}" if auto else "no row",
)
h.check(
    "a pause that was left alone leaves no row either",
    not h.listf(
        coord_token,
        "audit_events",
        f"action = 'spot.auto_resumed' && subject_id = '{still_waiting['id']}'",
    ),
    "the job skipped it, and a log that recorded the skip would grow a row per "
    "paused Spot per night",
)

h.check(
    "a pause that has NOT expired is left alone",
    spot_now(still_waiting["id"]).get("phase") == "paused",
    f"{spot_now(still_waiting['id']).get('phase')} — the filter must be on the "
    "date, not merely on the phase",
)

h.check(
    "an organisation that opted out keeps its Spot paused",
    spot_now(opted_out["id"]).get("phase") == "paused",
    f"{spot_now(opted_out['id']).get('phase')} — pause_auto_resume=false, and a "
    "setting that is read but not obeyed is worse than one that does not exist",
)

# ── The geocode cache purge ────────────────────────────────────────────────
#
# `geocode_cache` has no access rules at all — it is the proxy's own table — so
# the fixtures go in as the SUPERUSER, which bypasses them. That is also the
# point being made: nothing but the server touches this table, and the only
# thing that ever removes a row is this job.
#
# Written directly rather than by driving the proxy: the harness points
# EIERMANN_NOMINATIM_URL at a dead port on purpose, so a real lookup answers 502
# and caches nothing. What is under test is the purge, not the upstream.
expired = h.mk(
    T,
    "geocode_cache",
    {"kind": "forward", "cache_key": "abgelaufen", "response": {"results": []},
     "result_count": 0, "expires_at": h.stamp(days=-1)},
)
live = h.mk(
    T,
    "geocode_cache",
    {"kind": "forward", "cache_key": "frisch", "response": {"results": []},
     "result_count": 1, "expires_at": h.stamp(days=30)},
)


def cache_row_exists(row_id):
    status, _ = h.req("GET", f"/api/collections/geocode_cache/records/{row_id}", T)
    return status == 200


h.check("the cache fixtures are there to begin with",
        cache_row_exists(expired["id"]) and cache_row_exists(live["id"]))

gone = False
for _ in range(20):
    if not cache_row_exists(expired["id"]):
        gone = True
        break
    time.sleep(5)
h.check(
    "an expired cache row is purged by the job",
    gone,
    "still there after the wait — the purge either did not run or its filter "
    "does not match; the table then grows without bound and stale entries "
    "outlive their TTL forever, which is the one thing a cache must not do",
)
h.check(
    "...and a live one is left alone",
    cache_row_exists(live["id"]),
    "the purge must key on the EXPIRY, not merely on the table — a job that "
    "empties the cache every night makes it a cache in name only, and the "
    "upstream budget is somebody else's quota",
)

# The job must be idempotent: it runs every minute here and daily in production,
# and an already-active Spot must not be touched again. Watching `updated` is
# what catches a job that re-saves rows it has nothing to do with — invisible in
# the data, expensive at scale, and a source of spurious audit entries later.
before = spot_now(due["id"]).get("updated")
time.sleep(70)
h.check(
    "a second run does not touch the Spot it already resumed",
    spot_now(due["id"]).get("updated") == before,
    f"{before} -> {spot_now(due['id']).get('updated')}",
)

# ── The audit retention purge ──────────────────────────────────────────────
#
# eiermann-30w.10. The case the geocode comment above calls unreachable: this
# job keys on `created`, an autodate the SERVER owns, so no fixture can be
# backdated into the window. The window shrinks instead — and it is a SETTING
# rather than a constant, so nothing in the hook is patched to make this run.
#
# The default is 0, meaning keep forever, so up to this point the job has been
# running every minute and correctly deleting nothing. That is itself the first
# assertion.

print("\n[the audit retention purge]")


def audit_count(org=ORG):
    rows = h.listf(coord_token, "audit_events", f"org = '{org}'")
    return len(rows)


kept = audit_count()
h.check(
    "with retention off, a job that has run all suite long has purged nothing",
    kept > 0,
    f"{kept} rows — the default is 0 = keep forever, and a purge that ran "
    "anyway would have emptied the table before this line",
)

# About nine seconds. Small enough that rows written during this suite cross it
# while the test waits, large enough that the write itself is not racing it.
h.req(
    "PATCH",
    f"/api/collections/organisations/records/{ORG}",
    T,
    {"settings": {"audit_retention_days": 0.0001}},
)

deadline = time.time() + 130
purged = False
while time.time() < deadline:
    if audit_count() == 0:
        purged = True
        break
    time.sleep(3)

h.check(
    "with a window set, rows past it are purged",
    purged,
    f"{audit_count()} rows still there after the wait — the job either did not "
    "run, or its cutoff does not match. `created` is a server autodate, so a "
    "window this small is the only way a test can reach it at all",
)

# The guard, from the one direction the rule suite cannot reach. An API caller
# is refused by the null deleteRule before a hook runs; this asks whether the
# HOOK refuses too, which is the path `$app.delete` takes and the reason the
# guard exists at all.
h.req(
    "PATCH",
    f"/api/collections/organisations/records/{ORG}",
    T,
    {"settings": {"audit_retention_days": 0}},
)
h.mk(coord_token, "spots", {"org": ORG, "name": "Nach der Frist", "phase": "prospect"})
fresh = h.listf(coord_token, "audit_events", f"org = '{ORG}'")
h.check(
    "the log fills again once retention is off",
    len(fresh) > 0,
    "with the window back at 0 the purge must stop, or the table can never "
    "hold anything",
)
time.sleep(70)
h.check(
    "...and the next run leaves those rows alone",
    len(h.listf(coord_token, "audit_events", f"org = '{ORG}'")) >= len(fresh),
    "0 means keep forever, and a setting that is read but not obeyed is worse "
    "than one that does not exist",
)

sys.exit(h.summary())
