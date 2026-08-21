/// <reference path="../pb_data/types.d.ts" />

// A paused Spot comes back by itself once `paused_until` has passed.
//
// ── Why this is worth a cron ────────────────────────────────────────────────
//
// Without it `paused_until` is only a note to a human, and the pause ends when
// somebody remembers. That is the failure this app exists to remove, one level
// up: a Spot nobody has looked at for four months because the scaffolding came
// down in March and the pause did not.
//
// It is opt-out per organisation (`pause_auto_resume`, default true). A group
// that wants pauses to end by hand can have that; what it cannot have is a
// pause that ends silently and invisibly either way.
//
// ── The transition goes through app_spot_phase.apply ───────────────────────
//
// Not "set phase = active and save". `apply` is what clears `pause_reason` and
// `paused_until`, and what refuses a transition the graph does not allow. A
// second implementation of those invariants living in a cron is exactly how the
// two drift — and the cron is the copy nobody watches, because nothing about it
// appears on a screen.
//
// ── recomputeSpotDue, not setDue ───────────────────────────────────────────
//
// A resumed Spot with no due date is invisible in every list, which is the same
// outcome as still being paused. `setDue` exists for the request hooks, which
// hold the record they are about to save and must not mutate it after
// `e.next()`. A cron has no response to corrupt, so it takes the entry point
// that re-reads and saves: one derivation, and this is not the caller that needs
// the delicate one.

cronAdd("spotAutoResume", "20 4 * * *", () => {
  const rhythm = require(`${__hooks}/app_rhythm.js`);
  const phase = require(`${__hooks}/app_spot_phase.js`);
  const orgs = require(`${__hooks}/zv_org.js`);

  // `now` once, so a long run cannot resume a Spot whose date passed while it
  // was working — that Spot belongs to tomorrow's run, where it will be
  // included, rather than to a race.
  const now = new DateTime().string();

  let due;
  try {
    due = $app.findRecordsByFilter(
      "spots",
      "phase = 'paused' && paused_until != '' && paused_until <= {:now}",
      "paused_until",
      500,
      0,
      { now: now },
    );
  } catch (err) {
    $app.logger().warn("eiermann: auto-resume query failed", "err", String(err));
    return;
  }

  // One settings read per ORG rather than per Spot: a round of thirty paused
  // buildings in one organisation is one JSON parse, not thirty.
  const allowed = {};
  let resumed = 0;
  let skipped = 0;

  for (const spot of due) {
    const orgId = String(spot.get("org") || "");
    if (allowed[orgId] === undefined) {
      allowed[orgId] = orgs.settingsOf($app, orgId).pause_auto_resume !== false;
    }
    if (!allowed[orgId]) {
      skipped += 1;
      continue;
    }

    try {
      spot.set("phase", "active");
      // previous = "paused": the same call the request path makes, so the
      // cleanup and the transition check are the ones already under test.
      phase.apply(spot, "paused");
      $app.save(spot);
      rhythm.recomputeSpotDue($app, spot.id);
      resumed += 1;
    } catch (err) {
      // One Spot's failure must not end the round. A malformed row would
      // otherwise leave every later Spot paused, and the log would name only
      // the first one.
      $app
        .logger()
        .warn(
          "eiermann: auto-resume failed for one spot",
          "spot",
          spot.id,
          "err",
          String(err),
        );
    }
  }

  if (resumed || skipped) {
    $app
      .logger()
      .info(
        "eiermann: paused spots auto-resumed",
        "resumed",
        resumed,
        "skipped_by_setting",
        skipped,
      );
  }
});
