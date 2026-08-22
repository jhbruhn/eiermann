/// <reference path="../pb_data/types.d.ts" />

// eiermann-fi2.2 — the reporting core: what a period is, which rows fall in it,
// and every figure computed over them.
//
// Two consumers, one definition:
//   • report.pb.js — the Typst PDF, the funder summary and their CSV twin
//   • stats.pb.js  — GET /api/eiermann/stats, i.e. the statistics screen
//
// The screen and the printed report are answers to the same question, and a
// reader will put them side by side. So "2026" has to name the same instant
// range in both, "Eier entnommen" has to be the same sum, and a rate has to have
// the same denominator. That is only guaranteed with one implementation — a
// module, which is the ONE thing isolated hook handlers can share.
//
// Usage — `require()` INSIDE the handler, always in the absolute `${__hooks}`
// form (a file-level binding is a ReferenceError at request time, reported as a
// generic 400):
//
//   const stats = require(`${__hooks}/app_stats.js`);
//   const t = require(`${__hooks}/zv_time.js`).timeContext(query);
//   const period = stats.parsePeriod(query);
//   const bounds = stats.periodBounds(period, t);
//   const rows = stats.loadVisitRows(e.app, org, bounds, t);
//
// Named `app_*.js` and not `*.pb.js`, so PocketBase does not load it as a hook:
// it is only ever reachable through that require(). A required module keeps its
// own file-level scope, which is why the helpers below can live out here at all.
//
// STATELESS, like every other module here: PocketBase pools JSVMs and each
// pooled VM holds its own instance, so nothing may cache between calls.

/**
 * `?year=` + `?month=` → the reporting period: a calendar year, one month of
 * one, or `{year: null, month: null}` for everything on record.
 *
 * Refuses anything else with a CODE, rather than reporting on a period nobody
 * asked for. A garbled `?year=` would otherwise produce a confidently empty
 * report, which is worse than an error because it looks like an answer — and a
 * code rather than a sentence because the server does not know which language
 * the reader speaks.
 *
 * A month without a year is refused for the same reason: "März" alone names no
 * period, and silently reading it as "March this year" puts a figure on screen
 * the caller never asked for.
 */
function parsePeriod(query) {
  // Inside the function, absolute form: this module is loaded by handlers in
  // their own isolated JSVM contexts.
  const { refuse, CODES } = require(`${__hooks}/app_refuse.js`);
  const rawYear = query.get("year");
  let year = null;
  if (rawYear) {
    const parsed = parseInt(rawYear, 10);
    // Deliberately wide but finite.
    if (isNaN(parsed) || parsed < 1900 || parsed > 2200) {
      refuse(
        CODES.reportPeriodYearInvalid,
        "year must be a four-digit calendar year",
      );
    }
    year = parsed;
  }

  const rawMonth = query.get("month");
  let month = null;
  if (rawMonth) {
    const parsed = parseInt(rawMonth, 10);
    if (isNaN(parsed) || parsed < 1 || parsed > 12) {
      refuse(CODES.reportPeriodMonthInvalid, "month must be 1-12");
    }
    if (year === null) {
      refuse(CODES.reportPeriodMonthNeedsYear, "month requires a year");
    }
    month = parsed;
  }

  return { year: year, month: month };
}

/**
 * The half-open instant range of a period in the CALLER's zone, or null for an
 * all-time one.
 *
 * The offset is resolved from each boundary instant itself, so a January
 * boundary uses winter time and the period's own year does not shift — and a
 * summer month is not dragged an hour wide by the winter offset.
 *
 * This is the function that makes the New Year's Eve visit land in one year and
 * not two: the report filters on these bounds and the statistics route buckets
 * on the same `partsOf`, both resolved through the same offset.
 */
function periodBounds(period, t) {
  if (period.year === null) return null;
  const month = period.month === null ? 0 : period.month - 1;
  const naiveFrom = Date.UTC(period.year, month, 1);
  const naiveTo =
    period.month === null
      ? Date.UTC(period.year + 1, 0, 1)
      : Date.UTC(period.year, month + 1, 1);
  return {
    fromMs: naiveFrom - t.offsetFor(naiveFrom) * 60000,
    toMs: naiveTo - t.offsetFor(naiveTo) * 60000,
  };
}

/** How many days a period's month has (1-12 → 28..31). */
function daysInMonth(year, month) {
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

/** Reads a view row's column, decoding the json-typed ones. */
function viewReader(app, collectionName) {
  // ── Reading a view row ────────────────────────────────────────────────────
  // PocketBase can only infer a view column's type when it traces back to a
  // real collection field. In `visit_rows` the plain `v.*`/`s.*` projections do
  // (typed date/text/select as expected), but every COMPUTED column — the seven
  // state counts, `removed_real`, `added_dummy`, `findings_total`,
  // `findings_text` — falls back to type `json`, and `getString()` on a json
  // field returns the raw JSON: `"dead_bird; chick"` WITH the quotes, and `4`
  // as the string "4". The REST API decodes that on the way out, which is why
  // only a server-side reader ever sees it.
  //
  // Left un-decoded it is not cosmetic: a count would be `NaN` after Number(),
  // every findings breakdown would split on a leading quote, and the CSV's
  // formula guard would inspect a `"` instead of the `=` it exists to catch.
  //
  // So the json columns are asked for BY TYPE and decoded. Never sniffed per
  // value — a spot legitimately named `true` or a street named `123` parses as
  // JSON just fine, and that row would come back as a boolean.
  const jsonFields = {};
  for (const field of app.findCollectionByNameOrId(collectionName).fields) {
    if (field.type() === "json") jsonFields[field.getName()] = true;
  }
  return (record, name) => {
    const raw = record.getString(name);
    if (!jsonFields[name]) return raw;
    try {
      const parsed = JSON.parse(raw);
      return parsed === null ? "" : String(parsed);
    } catch (_) {
      // Not valid JSON after all — take it as written rather than dropping a
      // cell the report is supposed to print.
      return raw;
    }
  };
}

/** A non-negative integer from a view cell; absent or unparseable reads as 0. */
function count(value) {
  const parsed = parseInt(value, 10);
  return isNaN(parsed) || parsed < 0 ? 0 : parsed;
}

/**
 * The org's visits as `visit_rows` rows (1700000017), decoded and sorted oldest
 * first.
 *
 * `bounds` is the half-open period range from [periodBounds], or null for every
 * visit on record. `visited_at` is required on a visit, so there is no
 * undated-row case to keep — unlike federfall's admissions, where it exists.
 *
 * Unbounded reads are deliberate and cheap here: a visit is a trip to a
 * building, so a busy org writes a few thousand rows a year, not a few hundred
 * thousand. `stats.pb.js` reads ALL of them once and partitions in JS, which is
 * what lets the selected period, the previous year and the year list cost one
 * query instead of three.
 */
function loadVisitRows(app, org, bounds, t) {
  const bounded = bounds !== null && bounds !== undefined;
  const filter = bounded
    ? "org = {:org} && visited_at >= {:from} && visited_at < {:to}"
    : "org = {:org}";
  const params = bounded
    ? { org: org, from: t.pbStamp(bounds.fromMs), to: t.pbStamp(bounds.toMs) }
    : { org: org };
  const records = app.findRecordsByFilter(
    "visit_rows",
    filter,
    "",
    0,
    0,
    params,
  );

  const str = viewReader(app, "visit_rows");
  const rows = records.map((r) => {
    const visitedAt = str(r, "visited_at");
    return {
      id: r.id,
      spot: str(r, "spot"),
      spotName: str(r, "spot_name"),
      street: str(r, "street"),
      postalCode: str(r, "postal_code"),
      city: str(r, "city"),
      visitedAt: visitedAt,
      visitedMs: t.parseMs(visitedAt),
      outcome: str(r, "outcome"),
      skipReason: str(r, "skip_reason"),
      note: str(r, "note"),
      authorName: str(r, "author_name"),
      checksTotal: count(str(r, "checks_total")),
      swapped: count(str(r, "swapped_count")),
      partial: count(str(r, "partial_count")),
      empty: count(str(r, "empty_count")),
      untouched: count(str(r, "untouched_count")),
      notReachable: count(str(r, "not_reachable_count")),
      gone: count(str(r, "gone_count")),
      protectedChecks: count(str(r, "protected_count")),
      removedReal: count(str(r, "removed_real")),
      addedDummy: count(str(r, "added_dummy")),
      findingsTotal: count(str(r, "findings_total")),
      findingsText: str(r, "findings_text"),
    };
  });

  rows.sort((a, b) => {
    if (a.visitedMs !== b.visitedMs) {
      if (a.visitedMs === null) return 1;
      if (b.visitedMs === null) return -1;
      return a.visitedMs - b.visitedMs;
    }
    // A stable tiebreak, so two visits on the same day print in the same order
    // in the PDF and in the CSV of one export.
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });
  return rows;
}

/** Sorts a label→count map into `{label, count}`, highest first then label. */
function ranked(counts) {
  const list = Object.keys(counts).map((k) => ({ label: k, count: counts[k] }));
  list.sort((a, b) =>
    b.count !== a.count
      ? b.count - a.count
      : a.label < b.label
        ? -1
        : a.label > b.label
          ? 1
          : 0,
  );
  return list;
}

/**
 * A one-line address for a row: street, postal code and city, then the Spot's
 * own name if it adds anything.
 *
 * The address is the identity of a line in an authority report — a Behörde asks
 * about Musterstraße 5, not about "Altbau Hinterhof". The name is appended
 * rather than dropped, because for a building with no street recorded yet it is
 * the only thing that identifies the row at all.
 */
function addressOf(row) {
  const place = [row.postalCode, row.city].filter((p) => p).join(" ");
  const parts = [row.street, place].filter((p) => p);
  const address = parts.join(", ");
  if (!address) return row.spotName || "";
  if (row.spotName && row.spotName !== row.street) {
    return address + " (" + row.spotName + ")";
  }
  return address;
}

/**
 * Every figure the report and the statistics screen show, over `rows`.
 *
 * `opts.period` is `{year, month}` and decides the buckets: DAYS within a month,
 * months within a year, calendar years over all time. Every bucket of the period
 * is emitted even at zero — a week with no visits is a fact about that week, and
 * a chart that omits it reads as a list of the days that happened to have work.
 *
 * ── The rates, and why they are computed here ─────────────────────────────
 *
 * A rate is a share of the denominator that could have produced it, never of
 * everything that happened:
 *
 *   • `accessRate` — checked visits over ALL visits. Its denominator is the
 *     attempts, which is the question: how often does the team get in? A
 *     skipped visit is exactly what makes it interesting, so it belongs in the
 *     denominator and nowhere else.
 *   • `fullSwapRate` — clean swaps over the clutches actually ENCOUNTERED
 *     (`swapped + partial`). Over all checks it would sag every time the team
 *     finds more empty nests, which is when the work is going WELL — a number
 *     that falls on good news is a number people stop trusting. Empty,
 *     untouched, unreachable, gone and protected checks are therefore not in
 *     the denominator: none of them was a clutch that could have been swapped.
 *
 * Both are null — an undefined rate, not 0% — while nothing has happened yet.
 * The client renders "—" for null and must never coerce it to zero.
 *
 * `eggsPerCheckedVisit` is a FRACTIONAL mean over checked visits only: a visit
 * nobody got into did not have a chance to remove an egg, and averaging over it
 * understates the work by however often the caretaker was out.
 */
function aggregate(rows, opts) {
  const t = opts.t;
  const period = opts.period;
  const year = period.year;
  const month = period.month;

  const bump = (map, key) => {
    if (!key) return;
    map[key] = (map[key] || 0) + 1;
  };

  const addressCounts = {};
  const skipReasonCounts = {};
  const findingKindCounts = {};
  const buckets = {};
  const states = {
    swapped: 0,
    partial: 0,
    empty: 0,
    untouched: 0,
    not_reachable: 0,
    gone: 0,
    protected: 0,
  };
  let checked = 0;
  let skipped = 0;
  let checksTotal = 0;
  let removedReal = 0;
  let addedDummy = 0;
  let findingsTotal = 0;
  const spots = {};

  for (const r of rows) {
    if (r.outcome === "skipped") {
      skipped++;
      bump(skipReasonCounts, r.skipReason);
    } else {
      checked++;
    }
    bump(addressCounts, addressOf(r));
    if (r.spot) spots[r.spot] = true;
    checksTotal += r.checksTotal;
    states.swapped += r.swapped;
    states.partial += r.partial;
    states.empty += r.empty;
    states.untouched += r.untouched;
    states.not_reachable += r.notReachable;
    states.gone += r.gone;
    states.protected += r.protectedChecks;
    removedReal += r.removedReal;
    addedDummy += r.addedDummy;
    findingsTotal += r.findingsTotal;
    // The view joined the finding kinds with "; " into one cell (a
    // multi-relation cannot be a column otherwise), so the breakdown splits it
    // back apart. Safe because the kinds are WIRE values from a select field —
    // a free-text label containing "; " would mis-split, which is why
    // `species_label` is deliberately not in that column.
    if (r.findingsText) {
      for (const part of r.findingsText.split("; ")) {
        bump(findingKindCounts, part.trim());
      }
    }
    if (r.visitedMs !== null) {
      const p = t.partsOf(r.visitedAt);
      const key = month !== null ? p.d : year !== null ? p.mo : p.y;
      const bucket = buckets[key] || { visits: 0, removed: 0, dummies: 0 };
      bucket.visits++;
      bucket.removed += r.removedReal;
      bucket.dummies += r.addedDummy;
      buckets[key] = bucket;
    }
  }

  const pointFor = (key) => {
    const b = buckets[key] || { visits: 0, removed: 0, dummies: 0 };
    return { key: key, visits: b.visits, removed: b.removed, dummies: b.dummies };
  };
  const points = [];
  if (month !== null) {
    for (let d = 1; d <= daysInMonth(year, month); d++) points.push(pointFor(d));
  } else if (year !== null) {
    for (let m = 1; m <= 12; m++) points.push(pointFor(m));
  } else {
    const years = Object.keys(buckets)
      .map((k) => parseInt(k, 10))
      .sort((a, b) => a - b);
    if (years.length > 0) {
      // The whole span, filled in: a year with no visits is a zero column and
      // not a missing one, which is the difference between "we paused" and "we
      // have no data".
      for (let y = years[0]; y <= years[years.length - 1]; y++) {
        points.push(pointFor(y));
      }
    }
  }

  const clutches = states.swapped + states.partial;
  return {
    totals: {
      visits: rows.length,
      visitsChecked: checked,
      visitsSkipped: skipped,
      // Distinct buildings visited in the period — the figure a funder reads as
      // "how many houses does this group look after".
      spotsVisited: Object.keys(spots).length,
      checks: checksTotal,
      removedReal: removedReal,
      addedDummy: addedDummy,
      findings: findingsTotal,
      accessRate: rows.length === 0 ? null : checked / rows.length,
      fullSwapRate: clutches === 0 ? null : states.swapped / clutches,
      eggsPerCheckedVisit: checked === 0 ? null : removedReal / checked,
    },
    // Wire values, ordered as the state list is declared rather than by count:
    // this is a census of one enum and a reader compares it against the same
    // order in every report. `ranked()` is for the open-ended breakdowns below.
    checkStates: Object.keys(states).map((k) => ({
      label: k,
      count: states[k],
    })),
    addresses: ranked(addressCounts),
    skipReasons: ranked(skipReasonCounts),
    findingKinds: ranked(findingKindCounts),
    bucketKind: month !== null ? "day" : year !== null ? "month" : "year",
    points: points,
  };
}

/**
 * `rows` grouped by ADDRESS, each group carrying its own aggregate.
 *
 * This is the authority report's spine: a Behörde asks what happened at
 * Musterstraße 5, and the document answers per building rather than per trip.
 *
 * The per-group figures come from [aggregate] over the group's own rows — the
 * same function that produced the document's overall totals. Summing the
 * columns of the address table by hand would be a second implementation of
 * every rate in this module, and the two would disagree the first time either
 * was touched.
 *
 * Sorted by address, not by visit count: a reader looks up a building, and a
 * list ordered by how busy it was is a list they have to search linearly.
 * Grouping is by the RENDERED address, so a building recorded twice under the
 * same address appears as one group — which is what the reader is asking about,
 * even where the database disagrees.
 */
function groupByAddress(rows, opts) {
  const groups = {};
  const order = [];
  for (const r of rows) {
    const key = addressOf(r);
    if (!groups[key]) {
      groups[key] = {
        address: key,
        street: r.street,
        postalCode: r.postalCode,
        city: r.city,
        spotName: r.spotName,
        rows: [],
      };
      order.push(key);
    }
    groups[key].rows.push(r);
  }
  order.sort();
  return order.map((key) => {
    const group = groups[key];
    const agg = aggregate(group.rows, opts);
    return {
      address: group.address,
      street: group.street,
      postalCode: group.postalCode,
      city: group.city,
      spotName: group.spotName,
      totals: agg.totals,
      checkStates: agg.checkStates,
      findingKinds: agg.findingKinds,
      rows: group.rows,
    };
  });
}

/**
 * The Artbezeichnungen recorded on the findings of `rows`, ranked — exactly as
 * the `species_labels` view (1700000016) does for the org, but narrowed to this
 * period, which an org-wide view column cannot be.
 *
 * Its own read rather than a column on `visit_rows`: a free-text label is
 * user-typed and may contain the "; " that a joined cell splits on, so folding
 * it into `findings_text` would produce a value that mis-splits itself.
 */
function findingSpecies(app, org, rows) {
  const visitIds = {};
  for (const r of rows) visitIds[r.id] = true;

  const counts = {};
  for (const f of app.findRecordsByFilter(
    "findings",
    "org = {:org}",
    "",
    0,
    0,
    { org: org },
  )) {
    if (!visitIds[f.getString("visit")]) continue;
    const label = f.getString("species_label");
    if (!label) continue;
    counts[label] = (counts[label] || 0) + 1;
  }
  return ranked(counts);
}

/**
 * The org's Spots as they stand RIGHT NOW: how many per phase, and how far the
 * Erkundungen have got.
 *
 * ── Deliberately NOT period-scoped ────────────────────────────────────────
 *
 * Every other figure in this module answers a question about a period. This one
 * cannot: "how many buildings do we have access to" has nothing to do with
 * `?year=`, and narrowing it to the selected period would put a number on
 * screen that changes whenever the reader picks another year while describing
 * something that did not change at all. Callers must present it as a standing
 * figure, never inside a period's card.
 *
 * A phase or stage this build does not know is counted under its own wire value
 * rather than dropped, so the columns still add up to `total`.
 */
function spotStanding(app, org) {
  const rows = app.findRecordsByFilter("spots", "org = {:org}", "", 0, 0, {
    org: org,
  });
  const phases = {};
  const stages = {};
  for (const r of rows) {
    const phase = r.getString("phase") || "";
    phases[phase] = (phases[phase] || 0) + 1;
    if (phase === "prospect") {
      const stage = r.getString("prospect_stage") || "untouched";
      stages[stage] = (stages[stage] || 0) + 1;
    }
  }
  return {
    total: rows.length,
    phases: ranked(phases),
    // Only for the Spots that are still Erkundungen. A permitted building has
    // moved on to `phase = active` and counting its old stage again here would
    // report the funnel as twice as full as it is.
    prospectStages: ranked(stages),
  };
}

module.exports = {
  parsePeriod: parsePeriod,
  periodBounds: periodBounds,
  daysInMonth: daysInMonth,
  loadVisitRows: loadVisitRows,
  ranked: ranked,
  addressOf: addressOf,
  aggregate: aggregate,
  groupByAddress: groupByAddress,
  findingSpecies: findingSpecies,
  spotStanding: spotStanding,
};
