/// <reference path="../pb_data/types.d.ts" />

// Tour invariants: derived tenancy, derived snapshots, and the one-way door of
// `finished_at`.
//
// A module, `require`d inside each handler (see CLAUDE.md on JSVM contexts).
//
// ── Why any of this needs a hook ───────────────────────────────────────────
//
// `tour_spots` and `tour_runs` both have `createRule` = "the body's org is my
// org", and both point at a row the caller names by id. That is trap 11 in the
// exact shape it bit `nests`: the rule is satisfied by sending your OWN org, so
// your own org plus a FOREIGN tour id passes it. An access rule sees
// `@request.body.tour` as a string, not as a row it can dereference and ask who
// owns.
//
// So the parent is fetched, checked against the CALLER's org, and the tenancy
// field is taken from the parent rather than from the body.
//
// ── Why the snapshots are derived and not accepted ─────────────────────────
//
// `tour_name` and `started_by_name` exist so that a run still describes itself
// after its template or its walker's account is gone. A snapshot the client
// supplies is a snapshot that can LIE — and it would lie in the one direction
// nobody could catch, because the whole point of the field is that the thing it
// names may no longer exist to compare against. Copied from the server's own
// records, they are worth reading; sent by a client, they are decoration.
//
// Same argument for `started_by`: a run belongs to whoever started it, and
// "started by" is a fact about the request, not a field.

/** Read the caller's own org off the auth record — never off the body. */
function callerOrg(auth) {
  return auth ? String(auth.getString("org") || "") : "";
}

/** The human label for an account: its name, or its email if it has none. */
function callerName(auth) {
  if (!auth) return "";
  return String(auth.getString("name") || auth.getString("email") || "");
}

/**
 * Fetches the tour [tourId] and refuses unless it belongs to [org].
 *
 * The refusal for "belongs to somebody else" is deliberately the SAME code as
 * for "does not exist". Whether an id exists in another organisation is not
 * something a caller gets to learn, and two codes would tell them.
 */
function requireTour(app, tourId, org) {
  const { refuse, CODES } = require(`${__hooks}/app_refuse.js`);
  let tour;
  try {
    tour = app.findRecordById("tours", tourId);
  } catch (err) {
    refuse(CODES.tourNotFound, `tour not found: ${tourId}`);
  }
  if (String(tour.get("org") || "") !== String(org || "")) {
    refuse(CODES.tourNotFound, `tour not found: ${tourId}`);
  }
  return tour;
}

/**
 * A stop on a route: tenancy from the tour, and the Spot checked separately.
 *
 * Both parents have to be checked, and for different reasons. The TOUR is where
 * `org` comes from, so an unchecked one moves the row into another tenant. The
 * SPOT is not a source of anything — but an unchecked one puts a building
 * nobody in this org may read onto a route everybody in it walks, and the stop
 * then shows up in the running list as a row that cannot be opened. Neither is
 * a leak of the foreign row's contents; both are a route that lies.
 */
function deriveStop(app, record, org) {
  const { refuse, CODES } = require(`${__hooks}/app_refuse.js`);

  const tourId = String(record.get("tour") || "");
  if (!tourId) refuse(CODES.tourStopNeedsTour, "a stop requires a tour");
  const tour = requireTour(app, tourId, org);

  const spotId = String(record.get("spot") || "");
  if (!spotId) refuse(CODES.tourStopNeedsSpot, "a stop requires a spot");
  let spot;
  try {
    spot = app.findRecordById("spots", spotId);
  } catch (err) {
    refuse(CODES.tourStopSpotNotFound, `spot not found: ${spotId}`);
  }
  if (String(spot.get("org") || "") !== String(org || "")) {
    refuse(CODES.tourStopSpotNotFound, `spot not found: ${spotId}`);
  }

  record.set("org", tour.get("org"));
}

/**
 * A new run: who, when, and under what name.
 *
 * `tour` is optional and its absence is the ad-hoc round, so the empty case is
 * not an error path here — it is the other half of the feature. What it must
 * NOT be is half-set: a run with no template but a `tour_name` would read as a
 * run of a deleted route, which is a different and much worse claim than
 * "improvised".
 */
function prepareRun(app, record, auth) {
  const org = callerOrg(auth);
  const tourId = String(record.get("tour") || "");

  if (tourId) {
    const tour = requireTour(app, tourId, org);
    record.set("org", tour.get("org"));
    record.set("tour_name", String(tour.get("name") || ""));
  } else {
    record.set("org", org);
    // Cleared, not left alone. See the doc comment.
    record.set("tour_name", "");
  }

  record.set("started_by", auth ? auth.id : "");
  record.set("started_by_name", callerName(auth));
  // The server's clock, not the client's. A run starts when somebody starts it;
  // a backdated start would put its visits inside a window they were not walked
  // in, and the statistics in Phase 07 read exactly that window.
  record.set("started_at", new DateTime().string());
  // A run begins open. Sending `finished_at` on create would record a round
  // that was over before it began — and the resumable-run screen (avq.4) reads
  // this field alone to decide what is still going.
  record.set("finished_at", "");
}

/**
 * Finishing a run, and the fact that it only happens once.
 *
 * `finished_at` is the whole open/closed state — there is no `is_open` flag to
 * fall out of step with it. That makes it a one-way door, and the door has to be
 * enforced here rather than in the update rule: a rule reads a plain field
 * reference against the STORED record, so it can see that the row was finished,
 * but not that the incoming body is trying to blank it.
 *
 * Reopening is refused rather than silently ignored. The client would otherwise
 * show a run it believes it reopened, and every visit recorded after that would
 * land in a round its own timestamps say had ended.
 */
function guardFinish(record, previousFinishedAt) {
  const { refuse, CODES } = require(`${__hooks}/app_refuse.js`);
  const incoming = String(record.get("finished_at") || "");
  const previous = String(previousFinishedAt || "");

  // One condition, not two: "blanked it" and "moved it" are the same defect, and
  // a separate branch for reopening would carry a second dev message for a case
  // this one already covers. (Measured with a canary: removing the reopen branch
  // alone changed nothing, because this comparison catches it.)
  if (previous && incoming !== previous) {
    refuse(CODES.tourRunAlreadyFinished, "a run finishes once and cannot reopen");
  }
  // Stamped by the server for the same reason `started_at` is: the client says
  // THAT it is done, the server says when.
  if (!previous && incoming) {
    record.set("finished_at", new DateTime().string());
  }
}

module.exports = { deriveStop, prepareRun, guardFinish, callerOrg };
