// Node tests for the PURE half of the reporting core.
//
//   node backend/pocketbase/tests/unit/app_stats_test.js
//
// What these cover is the part every figure in the app depends on and that the
// live suite can only spot-check: the period arithmetic. Asserting that a
// December-31st visit lands in the right year needs one function call here and a
// contrived visit through the whole transactional endpoint over there.
//
// What they deliberately do NOT cover is anything reaching `app` — the view
// read, the findings narrowing, the standing Spot figures. A stub of
// `findRecordsByFilter` would only ever test the stub; those live in the rule
// suite, against a real PocketBase.

const assert = require("node:assert");
const { test } = require("node:test");
const path = require("node:path");

global.__hooks = path.join(__dirname, "..", "..", "pb_hooks");

// The PocketBase global app_refuse.js constructs a refusal out of, stubbed just
// far enough that the refusal can be inspected. `parsePeriod` refuses through
// `refuse(code, devMessage)`, and node has never heard of ApiError.
//
// The assertions below read the CODE, not the message: the code is the contract
// (the client maps it to an ARB string), while the message is an English
// developer line that PocketBase rewrites anyway.
global.ApiError = class ApiError extends Error {
  constructor(status, message, data) {
    super(message);
    this.status = status;
    this.data = data || {};
  }
};

/** The refusal code a call throws, or null if it did not refuse. */
const refusalCode = (fn) => {
  try {
    fn();
    return null;
  } catch (err) {
    if (!(err instanceof global.ApiError)) throw err;
    return Object.keys(err.data)[0] || null;
  }
};

const stats = require(path.join(global.__hooks, "app_stats.js"));

// ── The time context is a STUB here, deliberately ───────────────────────────
//
// The real one is `zv_time.js`, which lives in the base image and is not a file
// in this repo — so a node test cannot require it, and pretending to would only
// pin a copy that drifts from the original. It has its own unit tests in
// zugvogel.
//
// What these tests own is the arithmetic ON TOP of it: that `periodBounds` and
// the bucketing both resolve their offset through the SAME function, whichever
// function that is. So the stub supplies one offset and derives `partsOf` from
// it, exactly as zv_time does — the property under test is the agreement
// between the two consumers, not the offset itself.
//
// The end-to-end version, with the real module and a real visit, is in the rule
// suite: "the year boundary is the same in the report and in the statistics".
const contextAt = (offsetMinutes) => {
  const parseMs = (value) => {
    if (!value) return null;
    const d = new Date(String(value).replace(" ", "T"));
    return isNaN(d.getTime()) ? null : d.getTime();
  };
  return {
    offsetFor: () => offsetMinutes,
    parseMs: parseMs,
    partsOf: (value) => {
      const ms = parseMs(value);
      if (ms === null) return null;
      const local = new Date(ms + offsetMinutes * 60000);
      return {
        y: local.getUTCFullYear(),
        mo: local.getUTCMonth() + 1,
        d: local.getUTCDate(),
        h: local.getUTCHours(),
        mi: local.getUTCMinutes(),
      };
    },
    pbStamp: (ms) => new Date(ms).toISOString().replace("T", " "),
  };
};

/** A `?year=&month=&tzOffsetMinutes=` query, the way a route hands one over. */
const query = (params) => ({
  get: (name) => (params[name] === undefined ? "" : String(params[name])),
});

/** Central European winter time, the offset most of these are read in. */
const cet = () => contextAt(60);

test("a period is a year, a month of one, or everything on record", () => {
  assert.deepEqual(stats.parsePeriod(query({})), { year: null, month: null });
  assert.deepEqual(stats.parsePeriod(query({ year: 2026 })), {
    year: 2026,
    month: null,
  });
  assert.deepEqual(stats.parsePeriod(query({ year: 2026, month: 3 })), {
    year: 2026,
    month: 3,
  });
});

test("a garbled period is refused with a code, not silently reported on", () => {
  // Each of these would otherwise produce a confidently empty report, which is
  // worse than an error because it looks like an answer. And each says WHICH
  // parameter was wrong, because the client knows which one it sent.
  for (const params of [{ year: "letztes Jahr" }, { year: 26 }, { year: 3000 }]) {
    assert.equal(
      refusalCode(() => stats.parsePeriod(query(params))),
      "report_period_year_invalid",
      JSON.stringify(params),
    );
  }
  for (const params of [
    { year: 2026, month: 0 },
    { year: 2026, month: 13 },
    { year: 2026, month: "März" },
  ]) {
    assert.equal(
      refusalCode(() => stats.parsePeriod(query(params))),
      "report_period_month_invalid",
      JSON.stringify(params),
    );
  }
});

test("a month without a year names no period", () => {
  // Reading it as "March this year" would put a figure on screen that the
  // caller never asked for.
  assert.equal(
    refusalCode(() => stats.parsePeriod(query({ month: 3 }))),
    "report_period_month_needs_year",
  );
});

test("a period's bounds are the caller's midnight, not UTC's", () => {
  const t = contextAt(120);
  const bounds = stats.periodBounds({ year: 2026, month: null }, t);
  // 2026 begins at 00:00 in UTC+2, i.e. 22:00 on 31 December UTC. Reading the
  // year as a UTC range would put every visit of that evening in 2025.
  assert.equal(new Date(bounds.fromMs).toISOString(), "2025-12-31T22:00:00.000Z");
  assert.equal(new Date(bounds.toMs).toISOString(), "2026-12-31T22:00:00.000Z");
  assert.equal(stats.periodBounds({ year: null, month: null }, t), null);
});

test("each boundary resolves its OWN offset, so a summer month is not dragged wide", () => {
  // The stub returns one offset; the real zv_time returns a different one on
  // either side of the DST switch. What is asserted here is that each boundary
  // is passed through `offsetFor` separately rather than the period taking one
  // offset for both ends — a single lookup makes one month of the year an hour
  // long in the wrong direction, and a visit at 23:30 falls out of both.
  const seen = [];
  const t = Object.assign({}, cet(), {
    offsetFor: (ms) => {
      seen.push(ms);
      // Summer time from April, crudely: enough to make a shared offset visible.
      return new Date(ms).getUTCMonth() >= 3 ? 120 : 60;
    },
  });
  const march = stats.periodBounds({ year: 2026, month: 3 }, t);
  assert.equal(seen.length, 2, "one lookup per boundary");
  assert.equal(new Date(march.fromMs).toISOString(), "2026-02-28T23:00:00.000Z");
  assert.equal(new Date(march.toMs).toISOString(), "2026-03-31T22:00:00.000Z");
});

test("the year boundary is the SAME for the report's filter and the screen's bucket", () => {
  // eiermann-fi2.8, the invariant this whole module exists for: the report
  // selects rows with `visited_at >= from && < to`, while the statistics route
  // reads everything and buckets on the local year. If those two disagree, a
  // New Year's Eve visit is in the report and not in the chart — or in both
  // years at once, and the two documents no longer add up.
  const t = cet();
  const bounds = stats.periodBounds({ year: 2026, month: null }, t);
  const inFilter = (iso) => {
    const ms = t.parseMs(iso);
    return ms >= bounds.fromMs && ms < bounds.toMs;
  };
  const bucketYear = (iso) => t.partsOf(iso).y;

  // 00:30 local on New Year's Day, which is 23:30 UTC the evening before.
  const newYear = "2025-12-31 23:30:00.000Z";
  assert.equal(bucketYear(newYear), 2026);
  assert.equal(inFilter(newYear), true);

  // 23:30 local on New Year's Eve — the same UTC evening, half an hour earlier
  // in wall-clock terms and a whole year earlier in reporting terms.
  const newYearsEve = "2025-12-31 22:30:00.000Z";
  assert.equal(bucketYear(newYearsEve), 2025);
  assert.equal(inFilter(newYearsEve), false);
});

test("days in a month, including the leap one", () => {
  assert.equal(stats.daysInMonth(2026, 1), 31);
  assert.equal(stats.daysInMonth(2026, 2), 28);
  assert.equal(stats.daysInMonth(2028, 2), 29);
  assert.equal(stats.daysInMonth(2026, 4), 30);
});

/** A `visit_rows` row as loadVisitRows would have decoded it. */
function row(overrides) {
  const t = cet();
  const base = {
    id: "v" + Math.floor(Math.random() * 1e6),
    spot: "s1",
    spotName: "Haus",
    street: "Musterstraße 5",
    postalCode: "26121",
    city: "Oldenburg",
    visitedAt: "2026-03-10 09:00:00.000Z",
    outcome: "checked",
    skipReason: "",
    note: "",
    authorName: "Ada",
    checksTotal: 0,
    swapped: 0,
    partial: 0,
    empty: 0,
    untouched: 0,
    notReachable: 0,
    gone: 0,
    protectedChecks: 0,
    removedReal: 0,
    addedDummy: 0,
    findingsTotal: 0,
    findingsText: "",
  };
  const merged = Object.assign(base, overrides || {});
  merged.visitedMs = t.parseMs(merged.visitedAt);
  return merged;
}

const aggregateOf = (rows, period) =>
  stats.aggregate(rows, { t: cet(), period: period });

test("a rate is undefined rather than zero while nothing has happened", () => {
  const agg = aggregateOf([], { year: 2026, month: null });
  // Zero percent is a claim about the work; null is the absence of one, and the
  // screen renders "—". Coercing these to 0 would print a failure rate of 0%
  // and an access rate of 0% for an org that has not started yet.
  assert.equal(agg.totals.accessRate, null);
  assert.equal(agg.totals.fullSwapRate, null);
  assert.equal(agg.totals.eggsPerCheckedVisit, null);
  assert.equal(agg.totals.visits, 0);
});

test("the swap rate's denominator is the clutches encountered, not every check", () => {
  const agg = aggregateOf(
    [
      row({ checksTotal: 4, swapped: 3, partial: 1, removedReal: 6, addedDummy: 6 }),
      // Six empty nests: the team is finding fewer clutches, which is the work
      // going WELL. Over all checks the rate would sag on good news.
      row({ checksTotal: 6, empty: 6 }),
    ],
    { year: 2026, month: null },
  );
  assert.equal(agg.totals.fullSwapRate, 0.75);
  assert.equal(agg.totals.checks, 10);
  assert.equal(agg.totals.removedReal, 6);
  assert.equal(agg.totals.addedDummy, 6);
});

test("the access rate counts the trips that got in, over the trips made", () => {
  const agg = aggregateOf(
    [
      row({ checksTotal: 2, empty: 2 }),
      row({ outcome: "skipped", skipReason: "nobody_there" }),
      row({ outcome: "skipped", skipReason: "no_key" }),
      row({ outcome: "skipped", skipReason: "nobody_there" }),
    ],
    { year: 2026, month: null },
  );
  assert.equal(agg.totals.visits, 4);
  assert.equal(agg.totals.visitsChecked, 1);
  assert.equal(agg.totals.visitsSkipped, 3);
  assert.equal(agg.totals.accessRate, 0.25);
  // The reasons, ranked — this is the list a request for a key is argued with.
  assert.deepEqual(agg.skipReasons, [
    { label: "nobody_there", count: 2 },
    { label: "no_key", count: 1 },
  ]);
});

test("a skipped visit does not dilute the mean of what was removed", () => {
  const agg = aggregateOf(
    [
      row({ checksTotal: 1, swapped: 1, removedReal: 4 }),
      row({ outcome: "skipped", skipReason: "no_key" }),
    ],
    { year: 2026, month: null },
  );
  // 4 over ONE checked visit. Over both it would read 2, understating the work
  // by however often the caretaker was out.
  assert.equal(agg.totals.eggsPerCheckedVisit, 4);
});

test("the check-state census keeps the enum's order and adds up", () => {
  const agg = aggregateOf(
    [
      row({
        checksTotal: 7,
        swapped: 1,
        partial: 1,
        empty: 1,
        untouched: 1,
        notReachable: 1,
        gone: 1,
        protectedChecks: 1,
      }),
    ],
    { year: 2026, month: null },
  );
  assert.deepEqual(
    agg.checkStates.map((s) => s.label),
    ["swapped", "partial", "empty", "untouched", "not_reachable", "gone", "protected"],
  );
  const sum = agg.checkStates.reduce((acc, s) => acc + s.count, 0);
  assert.equal(sum, agg.totals.checks, "the census has to reconcile with the total");
});

test("every bucket of the period is emitted, even at zero", () => {
  const agg = aggregateOf(
    [row({ visitedAt: "2026-03-10 09:00:00.000Z", removedReal: 2, addedDummy: 2 })],
    { year: 2026, month: null },
  );
  assert.equal(agg.bucketKind, "month");
  assert.equal(agg.points.length, 12, "a year has twelve columns, not one");
  assert.deepEqual(agg.points[2], { key: 3, visits: 1, removed: 2, dummies: 2 });
  assert.deepEqual(agg.points[0], { key: 1, visits: 0, removed: 0, dummies: 0 });

  const month = aggregateOf(
    [row({ visitedAt: "2026-02-10 09:00:00.000Z" })],
    { year: 2026, month: 2 },
  );
  assert.equal(month.bucketKind, "day");
  assert.equal(month.points.length, 28);

  const allTime = aggregateOf(
    [
      row({ visitedAt: "2024-05-01 09:00:00.000Z" }),
      row({ visitedAt: "2026-05-01 09:00:00.000Z" }),
    ],
    { year: null, month: null },
  );
  assert.equal(allTime.bucketKind, "year");
  // 2025 had no visits and is a zero column, not a missing one: the difference
  // between "we paused" and "we have no data".
  assert.deepEqual(
    allTime.points.map((p) => p.key),
    [2024, 2025, 2026],
  );
  assert.equal(allTime.points[1].visits, 0);
});

test("a bucket is dated in the caller's calendar, not UTC's", () => {
  // 00:30 on 1 March in Berlin is 23:30 on 28 February UTC. Bucketing the UTC
  // day would put this visit in the wrong month of the chart while the report's
  // filter — which resolves the same offset — kept it in March.
  const agg = aggregateOf(
    [row({ visitedAt: "2026-02-28 23:30:00.000Z" })],
    { year: 2026, month: null },
  );
  assert.equal(agg.points[2].visits, 1, "March");
  assert.equal(agg.points[1].visits, 0, "February");
});

test("findings split back out of the joined cell, and addresses rank", () => {
  const agg = aggregateOf(
    [
      row({ findingsTotal: 2, findingsText: "dead_bird; chick" }),
      row({ findingsTotal: 1, findingsText: "dead_bird" }),
      row({ spot: "s2", street: "Andere Allee 1", spotName: "Andere Allee 1" }),
    ],
    { year: 2026, month: null },
  );
  assert.equal(agg.totals.findings, 3);
  assert.deepEqual(agg.findingKinds, [
    { label: "dead_bird", count: 2 },
    { label: "chick", count: 1 },
  ]);
  assert.deepEqual(agg.addresses, [
    { label: "Musterstraße 5, 26121 Oldenburg (Haus)", count: 2 },
    { label: "Andere Allee 1, 26121 Oldenburg", count: 1 },
  ]);
  assert.equal(agg.totals.spotsVisited, 2);
});

test("an address falls back to the Spot's name when no street is recorded", () => {
  // A building added from the map with nothing but a pin still has to identify
  // its own row — an empty first column is a line a reader cannot place.
  assert.equal(
    stats.addressOf(row({ street: "", postalCode: "", city: "", spotName: "Hinterhof Nord" })),
    "Hinterhof Nord",
  );
  assert.equal(
    stats.addressOf(row({ street: "", postalCode: "", city: "", spotName: "" })),
    "",
  );
  // The name is dropped only when it repeats the street.
  assert.equal(
    stats.addressOf(row({ spotName: "Musterstraße 5" })),
    "Musterstraße 5, 26121 Oldenburg",
  );
});

test("the address groups carry the aggregate, not a hand-summed column", () => {
  const rows = [
    row({ street: "Zweite Straße 2", checksTotal: 2, swapped: 2, removedReal: 4 }),
    row({ spot: "s2", street: "Erste Straße 1", checksTotal: 1, partial: 1, removedReal: 1 }),
    row({ spot: "s2", street: "Erste Straße 1", outcome: "skipped", skipReason: "no_key" }),
  ];
  const groups = stats.groupByAddress(rows, {
    t: cet(),
    period: { year: 2026, month: null },
  });
  // Sorted by address: a reader looks a building up, they do not scan for it.
  assert.deepEqual(
    groups.map((g) => g.address),
    ["Erste Straße 1, 26121 Oldenburg (Haus)", "Zweite Straße 2, 26121 Oldenburg (Haus)"],
  );
  assert.equal(groups[0].totals.visits, 2);
  assert.equal(groups[0].totals.visitsSkipped, 1);
  assert.equal(groups[0].totals.accessRate, 0.5);
  // The group's rate comes from the same function as the document's, so a
  // group of one clutch found half-swapped reads 0 and not "no data".
  assert.equal(groups[0].totals.fullSwapRate, 0);
  assert.equal(groups[1].totals.fullSwapRate, 1);
  assert.equal(groups[1].totals.removedReal, 4);
  // The whole period's figures have to be the groups' figures added up, or the
  // document contradicts itself between its table and its header.
  const whole = aggregateOf(rows, { year: 2026, month: null });
  assert.equal(
    groups.reduce((acc, g) => acc + g.totals.removedReal, 0),
    whole.totals.removedReal,
  );
  assert.equal(
    groups.reduce((acc, g) => acc + g.totals.visits, 0),
    whole.totals.visits,
  );
});

test("one address recorded as two Spots is one group", () => {
  // The reader is asking about a building. Two rows in `spots` for the same
  // address — a duplicate somebody entered from the map — is a fact about the
  // database, not about the house, and a report that lists it twice invites the
  // question of which line is the real one.
  const groups = stats.groupByAddress(
    [row({ spot: "s1" }), row({ spot: "s2" })],
    { t: cet(), period: { year: 2026, month: null } },
  );
  assert.equal(groups.length, 1);
  assert.equal(groups[0].totals.visits, 2);
});
