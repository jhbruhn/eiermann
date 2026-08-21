#!/usr/bin/env python3
"""eiermann-gb1 — the auto-resume cron, observed actually running.

Driven by run_cron.sh, which rewrites the schedule to every minute. Nothing an
HTTP request can do triggers a `cronAdd` job, so without this suite the job
could be wrong indefinitely and every rule assertion would stay green.

What is asserted is the OUTCOME of a real run, not a simulation of one: a Spot
whose `paused_until` has passed comes back to `active`, with the pause fields
cleared and a fresh due date; an organisation that opted out keeps its Spot
paused. A test that called the handler directly would prove the function works
and say nothing about whether it is wired to a schedule at all.
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

sys.exit(h.summary())
