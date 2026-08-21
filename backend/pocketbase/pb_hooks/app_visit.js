/// <reference path="../pb_data/types.d.ts" />

// POST /api/eiermann/visit — the whole Besuch, in ONE transaction.
//
// ── Why one call and not seven ─────────────────────────────────────────────
//
// The obvious shape is a REST write per nest as the volunteer works through
// them. It fails in a way that is worse than an error: if the connection drops
// after the second nest, the database holds a visit in which five nests were not
// checked — and that is INDISTINGUISHABLE from five nests somebody deliberately
// did not touch. Both are "no check row". No later screen can tell them apart,
// and no repair is possible because the information was never recorded.
//
// So a partial visit must not be representable. The endpoint takes the whole
// Besuch as one body, writes it inside `app.runInTransaction`, and the create
// rules on visits/nest_checks/nest_eggs are null so that no other path exists.
//
// This is also the answer to "the app has no offline mode". The visit form holds
// everything in memory and submits on completion, so in a cellar with no signal
// exactly ONE call fails, at a named point, with a retry button that is safe to
// press three times. The form survives losing reception; it does not survive the
// app being killed, and that is a stated limit rather than a bug.
//
// ── Idempotency ────────────────────────────────────────────────────────────
//
// The retry button is only safe because of the Idempotency-Key. A replay with
// the same key returns the STORED response rather than writing a second visit.
// Without it, "press it three times" produces three visits, three sets of
// checks, and a rhythm advanced three times — the exact damage the retry was
// meant to avoid.
//
// The key is scoped to (key, user, route): one person's key cannot collide with
// another's, and the same key on a different route is a different operation.

/** How long a stored idempotent response stays replayable. */
const REPLAY_DAYS = 2;

/**
 * A stable fingerprint of a request body.
 *
 * `JSON.stringify` alone is NOT stable here, and this cost a debugging round:
 * `e.requestInfo().body` is a Go `map[string]any` handed across to JS, and Go
 * randomises map iteration order deliberately. So the same bytes from the client
 * serialise to a different key order on every request, and a hash of that gives
 * a different value each time — which made a legitimate retry look like a key
 * reused for a different visit, and answer 409.
 *
 * Sorting the keys at every level fixes it and has a second benefit: a client
 * that reorders its own JSON between attempts still matches. Arrays keep their
 * order, because in a visit body they are the nests and the order of the checks
 * is part of what was sent.
 */
function canonical(value) {
  if (value === null || typeof value !== "object") return value;
  if (Array.isArray(value)) return value.map(canonical);
  const out = {};
  for (const key of Object.keys(value).sort()) out[key] = canonical(value[key]);
  return out;
}

function fingerprint(body) {
  return $security.sha256(JSON.stringify(canonical(body || {})));
}

/**
 * The stored response for this key, or null.
 *
 * A hit returns the ORIGINAL status too: a replay of a request that failed
 * validation must fail the same way, or the client learns that retrying changes
 * the answer.
 *
 * Throws a 409 if the key was used for a DIFFERENT body. Answering with the
 * first request's result would mean the second visit is never written while the
 * app reports success — a visit that vanishes and looks like one nobody made.
 */
function replay(app, key, userId, route, body) {
  if (!key) return null;
  const rows = app.findRecordsByFilter(
    "idempotency_keys",
    "key = {:key} && user = {:user} && route = {:route}",
    "-created",
    1,
    0,
    { key: key, user: userId, route: route },
  );
  if (!rows.length) return null;
  const row = rows[0];
  if (String(row.get("expires_at") || "") < new DateTime().string()) return null;

  const stored = String(row.get("request_hash") || "");
  if (stored && stored !== fingerprint(body)) {
    throw new ApiError(
      409,
      "Dieser Idempotency-Key wurde schon für einen anderen Besuch verwendet. " +
        "Für jeden Besuch einen neuen Schlüssel erzeugen.",
      {},
    );
  }

  return {
    status: Number(row.get("status") || 200),
    // JSONRaw goes straight back to Go. Reading into it in JS would yield a byte
    // array and silently produce `{}` — see zv_org.js.
    body: row.get("response"),
  };
}

/** Stores [body] under [key] so a retry replays it. */
function remember(app, key, userId, route, status, body, request) {
  if (!key) return;
  const rhythm = require(`${__hooks}/app_rhythm.js`);
  const collection = app.findCollectionByNameOrId("idempotency_keys");
  const row = new Record(collection);
  row.set("key", key);
  row.set("user", userId);
  row.set("route", route);
  row.set("status", status);
  row.set("request_hash", fingerprint(request));
  row.set("response", JSON.stringify(body));
  row.set("expires_at", rhythm.addDays(new DateTime().string(), REPLAY_DAYS));
  app.save(row);
}

/**
 * Verifies `*_after = *_before − removed + added` for one check payload.
 *
 * Server-side because a client that can send inconsistent numbers makes a nest's
 * egg count drift from its own history — and the drift is invisible, since every
 * individual screen looks plausible. The client computes these for display; only
 * this function decides whether they are true.
 */
function checkArithmetic(payload) {
  const n = (key) => {
    const value = Number(payload[key] || 0);
    return isNaN(value) || value < 0 ? 0 : Math.floor(value);
  };
  const realBefore = n("real_before");
  const dummyBefore = n("dummy_before");
  const removedReal = n("removed_real");
  const addedDummy = n("added_dummy");

  if (removedReal > realBefore) {
    throw new BadRequestError(
      "Es können nicht mehr echte Eier entnommen werden, als im Nest waren.",
    );
  }
  const realAfter = realBefore - removedReal;
  const dummyAfter = dummyBefore + addedDummy;

  // The client's own numbers are checked rather than ignored: a mismatch means
  // the two sides disagree about what just happened, and silently overwriting
  // would hide a real bug in the form.
  for (const [key, expected] of [
    ["real_after", realAfter],
    ["dummy_after", dummyAfter],
  ]) {
    if (payload[key] !== undefined && n(key) !== expected) {
      throw new BadRequestError(
        `Die Eierzahlen gehen nicht auf: ${key} ist ${n(key)}, ` +
          `erwartet ${expected}.`,
      );
    }
  }

  return {
    real_before: realBefore,
    dummy_before: dummyBefore,
    removed_real: removedReal,
    added_dummy: addedDummy,
    real_after: realAfter,
    dummy_after: dummyAfter,
  };
}

/**
 * `partial` means a real egg is still in the nest afterwards — the Halbgelege.
 *
 * Derived from the arithmetic rather than trusted from the client, because the
 * follow-up that keeps a half clutch from hatching unnoticed hangs off exactly
 * this flag. A client that could mislabel it would close the gap the second
 * field problem is about.
 */
function reconcileState(state, numbers) {
  if (state !== "swapped" && state !== "partial") return state;
  return numbers.real_after > 0 ? "partial" : "swapped";
}

/** Rewrites `nest_eggs` to match the check's outcome. */
function rewriteEggs(app, nest, check, numbers) {
  const existing = app.findRecordsByFilter(
    "nest_eggs", "nest = {:nest}", "slot_index", 200, 0, { nest: nest.id },
  );
  // `since` is per EGG and must survive a rewrite: a dummy that has sat for
  // three months is a nest the birds have given up on, and resetting the date on
  // every visit would erase exactly that signal. So the dates of the eggs that
  // stayed are carried over, oldest first, and only genuinely new eggs get
  // today's date.
  const carried = { real: [], dummy: [] };
  for (const row of existing) {
    const kind = String(row.get("kind") || "");
    if (carried[kind]) carried[kind].push(String(row.get("since") || ""));
    app.delete(row);
  }
  carried.real.sort();
  carried.dummy.sort();

  const collection = app.findCollectionByNameOrId("nest_eggs");
  const checkedAt = String(check.get("checked_at") || "");
  let slot = 0;
  for (const kind of ["real", "dummy"]) {
    const count = kind === "real" ? numbers.real_after : numbers.dummy_after;
    for (let i = 0; i < count; i++) {
      const row = new Record(collection);
      row.set("org", nest.get("org"));
      row.set("nest", nest.id);
      row.set("slot_index", slot++);
      row.set("kind", kind);
      row.set("since", carried[kind].length ? carried[kind].shift() : checkedAt);
      row.set("source_check", check.id);
      app.save(row);
    }
  }
}

/**
 * Writes the whole visit. Called inside a transaction; throws to roll it all
 * back.
 */
function writeVisit(app, auth, body) {
  const rhythm = require(`${__hooks}/app_rhythm.js`);
  const nestRules = require(`${__hooks}/app_nest_rules.js`);

  const orgId = String(auth.getString("org") || "");
  const authorName = String(auth.getString("name") || auth.getString("email") || "");
  const spotId = String(body.spot || "");
  if (!spotId) throw new BadRequestError("Ein Besuch braucht einen Spot.");

  let spot;
  try {
    spot = app.findRecordById("spots", spotId);
  } catch (_) {
    throw new BadRequestError("Der angegebene Spot existiert nicht.");
  }
  // Tenancy from the STORED row, and the same message either way: whether an id
  // exists in another organisation is not something a caller gets to learn.
  if (String(spot.get("org") || "") !== orgId) {
    throw new BadRequestError("Der angegebene Spot existiert nicht.");
  }

  const outcome = String(body.outcome || "");
  if (outcome !== "checked" && outcome !== "skipped") {
    throw new BadRequestError('`outcome` muss "checked" oder "skipped" sein.');
  }
  const visitedAt = String(body.visited_at || "") || new DateTime().string();

  const visits = app.findCollectionByNameOrId("visits");
  const visit = new Record(visits);
  visit.set("org", orgId);
  visit.set("spot", spot.id);
  visit.set("visited_at", visitedAt);
  visit.set("outcome", outcome);
  visit.set("note", String(body.note || ""));
  visit.set("author", auth.id);
  visit.set("author_name", authorName);
  if (outcome === "skipped") {
    const reason = String(body.skip_reason || "");
    if (!reason) {
      // A skip without a reason is the same failure as a pause without one: the
      // record cannot say whether anybody tried.
      throw new BadRequestError("Ein ausgelassener Besuch braucht einen Grund.");
    }
    visit.set("skip_reason", reason);
    visit.set("skip_note", String(body.skip_note || ""));
  }
  app.save(visit);

  const checkPayloads = Array.isArray(body.checks) ? body.checks : [];
  if (outcome === "skipped" && checkPayloads.length) {
    // A skipped visit documents a non-event. Checks inside one would be an
    // observation, and the rhythm would then advance on a nest nobody saw.
    throw new BadRequestError(
      "Ein ausgelassener Besuch kann keine Nestprüfungen enthalten.",
    );
  }

  const checksCollection = app.findCollectionByNameOrId("nest_checks");
  const written = [];
  const seen = {};
  for (const payload of checkPayloads) {
    const nestId = String(payload.nest || "");
    if (!nestId) throw new BadRequestError("Eine Nestprüfung braucht ein Nest.");
    if (seen[nestId]) {
      // Two checks on one nest in one visit cannot both be true, and the rhythm
      // would apply twice.
      throw new BadRequestError("Ein Nest kann pro Besuch nur einmal geprüft werden.");
    }
    seen[nestId] = true;

    let nest;
    try {
      nest = app.findRecordById("nests", nestId);
    } catch (_) {
      throw new BadRequestError("Das angegebene Nest existiert nicht.");
    }
    if (String(nest.get("org") || "") !== orgId) {
      throw new BadRequestError("Das angegebene Nest existiert nicht.");
    }
    if (String(nest.get("spot") || "") !== spot.id) {
      throw new BadRequestError(
        "Das Nest gehört nicht zu diesem Spot.",
      );
    }

    const state = String(payload.state || "");
    const touchesEggs = state === "swapped" || state === "partial";
    if (touchesEggs) {
      // THE PROTECTED-SPECIES GUARD, on the transactional path. Every egg
      // mutation goes through here, and it throws — which rolls back the whole
      // visit rather than writing the other nests and skipping this one. A
      // warning would be the wrong shape: §44 BNatSchG is not advisory.
      nestRules.assertEggsAllowed(nest);
    }

    const numbers = touchesEggs
      ? checkArithmetic(payload)
      : {
          real_before: 0, dummy_before: 0, removed_real: 0,
          added_dummy: 0, real_after: 0, dummy_after: 0,
        };

    const check = new Record(checksCollection);
    check.set("org", orgId);
    check.set("visit", visit.id);
    check.set("nest", nest.id);
    check.set("state", touchesEggs ? reconcileState(state, numbers) : state);
    for (const key of Object.keys(numbers)) check.set(key, numbers[key]);
    check.set("note", String(payload.note || ""));
    check.set("author", auth.id);
    check.set("author_name", authorName);
    check.set("checked_at", visitedAt);
    app.save(check);

    // A nest reported `protected` on a visit IS the species being determined —
    // the volunteer is standing in front of it. Recording the check without
    // marking the nest would leave the egg-swap path open on the next visit.
    if (state === "protected" && String(nest.get("species")) !== "protected") {
      nest.set("species", "protected");
      if (payload.species_label) {
        nest.set("species_label", String(payload.species_label));
      }
      app.save(nest);
    }

    if (touchesEggs) rewriteEggs(app, nest, check, numbers);
    rhythm.applyCheck(app, nest, check);
    written.push({ id: check.id, nest: nest.id, state: String(check.get("state")) });
  }

  const findingsCollection = app.findCollectionByNameOrId("findings");
  const findings = [];
  for (const payload of Array.isArray(body.findings) ? body.findings : []) {
    const finding = new Record(findingsCollection);
    finding.set("org", orgId);
    finding.set("visit", visit.id);
    finding.set("spot", spot.id);
    if (payload.nest) {
      const nestId = String(payload.nest);
      if (!seen[nestId]) {
        // A finding on a nest this visit did not check would attach an
        // observation to a nest nobody looked at.
        let nest;
        try {
          nest = app.findRecordById("nests", nestId);
        } catch (_) {
          throw new BadRequestError("Das angegebene Nest existiert nicht.");
        }
        if (String(nest.get("spot") || "") !== spot.id) {
          throw new BadRequestError("Das Nest gehört nicht zu diesem Spot.");
        }
      }
      finding.set("nest", nestId);
    }
    finding.set("kind", String(payload.kind || ""));
    finding.set("count", Number(payload.count || 1));
    finding.set("species_label", String(payload.species_label || ""));
    finding.set("note", String(payload.note || ""));
    finding.set("author", auth.id);
    finding.set("author_name", authorName);
    finding.set("found_at", visitedAt);
    app.save(finding);
    findings.push({ id: finding.id, kind: String(finding.get("kind")) });
  }

  // Last, and after everything else: the Spot's date is the minimum over the
  // nests and follow-ups this visit just changed.
  rhythm.recomputeSpotDue(app, spot.id);

  return { visit: visit.id, checks: written, findings: findings };
}

module.exports = {
  REPLAY_DAYS,
  canonical,
  fingerprint,
  replay,
  remember,
  checkArithmetic,
  reconcileState,
  rewriteEggs,
  writeVisit,
};
