/// <reference path="../pb_data/types.d.ts" />

// eiermann-30w.10 — the only way a row ever leaves `audit_events`, and the
// guard that makes "append-only" true against this app's own hooks.
//
// ── The hole this closes, which exists whether or not anything expires ─────
//
// 1700000024 makes the table append-only by nulling `createRule`, `updateRule`
// and `deleteRule`. That is the strongest statement PocketBase offers and it is
// absolute — against anything holding an API TOKEN. It says nothing at all
// about a hook: `$app.save` and `$app.delete` do not consult access rules, which
// is exactly why the emitters can write here in the first place.
//
// So for as long as no hook deleted from this table, the schema was the whole
// story. The moment one does, it stops being — and the guard below is what
// takes over. The model hooks (`onRecordUpdate`, `onRecordDelete`, not the
// *Request variants) fire for hook-driven writes too, which is precisely the
// path the rules cannot see.
//
// ── Why permission is derived from the ROW, not from the caller ────────────
//
// federfall's reasoning, and it holds here unchanged. The cron below has to be
// able to purge and cannot announce itself: JSVM module state is per-VM rather
// than global, so there is no shared "I am the purger" flag a guard could
// trust — and a flag that COULD be set is one any other hook could set too.
//
// Deriving permission from the record removes the question. A row may be
// deleted only once it is older than its organisation's window, whoever is
// asking. The cron therefore needs no privilege the guard does not already
// grant, which is what lets the guard be absolute and stateless at once: a bug
// in the cron degrades to "nothing was purged", never to "history was quietly
// rewritten".
//
// MEASURED, not assumed. Making the cron ignore `days === 0` and purge with a
// nine-second window left the cron test entirely green: every `$app.delete` was
// refused by the guard below, and the rows survived a job actively trying to
// remove them. Only breaking BOTH layers moved the suite. So the belt and the
// braces are real and independent — and the cron test cannot, by itself, tell
// you which of the two is holding.
//
// ── eiermann keeps forever by default, and federfall does not ──────────────
//
// federfall defaults `audit_retention_days` to 730. This app defaults it to 0,
// which means keep forever, and the machinery here is an OPT-IN rather than a
// schedule that starts running the day it ships.
//
// The reason is that the two products hold different logs. federfall's records
// a rehabilitation clinic's handling of animals, at a volume and under
// obligations that make a bounded window the sober default. This one records a
// volunteer group deciding which attic to check next, plus the handful of acts
// that are hard to undo; it writes no `ip` and no `user_agent` by design
// (1700000024), and its whole yearly volume is a few thousand rows. Against
// that, the failure mode the table exists to prevent — a log that quietly
// forgets — costs more than the storage does.
//
// So the window exists, is per-organisation, and is off until somebody sets it.
// Changing that is one number in `organisations.settings`, not a migration:
//
//   { "audit_retention_days": 730 }   // 0 or unset = keep forever
//
// `organisations.updateRule` is null and the rhythm route takes five typed
// fields, none of them this one — so setting it is a superuser act. That is the
// right level: how long an accountability log is kept is an operator's decision
// about the instance, not a coordinator's about their week.

// Append-only means append-only: no edit, from anywhere, for any reason. There
// is no window that makes rewriting a row acceptable, which is why this one has
// no condition in it at all.
onRecordUpdate((e) => {
  const { refuse, CODES } = require(`${__hooks}/app_refuse.js`);
  refuse(CODES.auditAppendOnly, "audit_events is append-only");
}, "audit_events");

onRecordDelete((e) => {
  const { refuse, CODES } = require(`${__hooks}/app_refuse.js`);
  const DAY_MS = 24 * 60 * 60 * 1000;
  const rec = e.record;

  // `created` is an autodate — "2026-08-04 09:12:33.123Z" — and JS needs the T.
  const raw = rec.getString("created");
  const created = raw ? new Date(String(raw).replace(" ", "T")) : null;
  if (!created || isNaN(created.getTime())) {
    // A row whose age cannot be established can never clear the floor. Failing
    // CLOSED here is the whole point: an unreadable timestamp must not become a
    // deletable row.
    refuse(CODES.auditAppendOnly, "audit row has no readable created stamp");
  }

  // A JSON field hands the JSVM a byte array whose every property reads
  // `undefined`, so this goes through the one reader that decodes it. Never
  // `record.get("settings")`.
  const orgSettings = require(`${__hooks}/zv_org.js`);
  const days = orgSettings.positiveNumber(
    orgSettings.settingsOf(e.app, rec.getString("org")),
    "audit_retention_days",
    0,
    // `allowZero`, because 0 is a legitimate instruction here rather than a
    // malformed number: it means keep forever, and it is this app's default.
    { allowZero: true },
  );

  if (days === 0) {
    refuse(
      CODES.auditRetentionDisabled,
      "audit retention is disabled for this organisation",
    );
  }

  const floor = new Date().getTime() - days * DAY_MS;
  if (created.getTime() >= floor) {
    refuse(
      CODES.auditWithinRetention,
      "audit row is still inside its organisation's retention window",
    );
  }

  e.next();
}, "audit_events");

// The purge. Deletes exactly what the guard above would let an operator delete,
// which is why it needs no privilege of its own.
//
// `cronAdd` jobs are invisible to the rule suite — nothing an HTTP request can
// do will trigger one — so this has its own harness with the schedule rewritten
// (`run_cron.sh`). The WINDOW is rewritten there too: it is measured against
// `created`, which belongs to the server, so a test cannot backdate a row into
// it and has to make the window vanishingly small instead.
cronAdd("auditRetention", "30 3 * * *", () => {
  const DAY_MS = 24 * 60 * 60 * 1000;
  const PAGE = 500;

  let orgs = [];
  try {
    orgs = $app.findRecordsByFilter("organisations", "id != ''", "", 500, 0);
  } catch (err) {
    $app.logger().warn("audit retention: cannot list orgs", "err", String(err));
    return;
  }

  const orgSettings = require(`${__hooks}/zv_org.js`);
  let purgedTotal = 0;

  for (const org of orgs) {
    const days = orgSettings.positiveNumber(
      orgSettings.settingsOf($app, org.id),
      "audit_retention_days",
      0,
      { allowZero: true },
    );
    // The default, and the common case: this organisation keeps its log.
    if (days === 0) continue;

    const cutoff = new Date(new Date().getTime() - days * DAY_MS)
      .toISOString()
      .replace("T", " ");

    let purged = 0;
    for (;;) {
      let batch;
      try {
        batch = $app.findRecordsByFilter(
          "audit_events",
          "org = {:org} && created < {:cutoff}",
          "created",
          PAGE,
          // Offset 0 every round, deliberately: deleting shrinks the result
          // set, so the next page of still-expired rows slides to the front. An
          // advancing offset would step over exactly as many rows as it removed.
          0,
          { org: org.id, cutoff: cutoff },
        );
      } catch (err) {
        $app
          .logger()
          .warn(
            "audit retention: query failed",
            "org",
            org.id,
            "err",
            String(err),
          );
        break;
      }
      if (!batch || batch.length === 0) break;

      let deletedThisBatch = 0;
      for (const row of batch) {
        try {
          $app.delete(row);
          deletedThisBatch += 1;
        } catch (err) {
          // The guard refused it, or the row went in the meantime. Either way
          // one row's failure must not end the round for the rest.
          $app
            .logger()
            .warn(
              "audit retention: row not purged",
              "row",
              row.id,
              "err",
              String(err),
            );
        }
      }
      purged += deletedThisBatch;
      // Nothing in this batch could be deleted, so another identical query
      // would return the same rows forever.
      if (deletedThisBatch === 0) break;
      if (batch.length < PAGE) break;
    }

    if (purged) {
      purgedTotal += purged;
      $app
        .logger()
        .info(
          "eiermann: audit rows purged",
          "org",
          org.id,
          "purged",
          purged,
          "retention_days",
          days,
        );
    }
  }

  if (purgedTotal) {
    $app.logger().info("eiermann: audit retention run", "purged", purgedTotal);
  }
});
