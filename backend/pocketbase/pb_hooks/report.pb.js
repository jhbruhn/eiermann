/// <reference path="../pb_data/types.d.ts" />

// eiermann-fi2.6 — GET /api/eiermann/reports/period: the proof that keeps a
// permission or a funding alive.
//
// ── ONE route, three formats ────────────────────────────────────────────────
//
//   ?format=pdf      (default) the Behördenbericht per address — typst/report.typ
//   ?format=summary  the Förderer-Zusammenfassung             — typst/summary.typ
//   ?format=csv      the same table as a spreadsheet
//
// One route and not three, because every routerAdd handler is its own isolated
// JSVM context: three handlers would each have to build the period, the row set
// and the localization again. What CAN be shared is a required module, and that
// is exactly what app_stats.js is — shared further still, with the statistics
// route, so the screen and the printed page cannot disagree about what a year is
// or how a rate is computed.
//
// All three read `visit_rows` (1700000017) and none of them selects a column of
// its own. That view is the single definition of the report table; the CSV is
// its rows, the PDF is its rows grouped by address, and the summary is its rows
// aggregated. They cannot drift apart because there is nothing to drift.
//
// ── The CSV is why this hook localizes anything ─────────────────────────────
//
// A hook never sends user-facing text — the server does not know which language
// the reader speaks. The PDFs obey that: the hook ships wire values and the
// Typst templates translate. A CSV has no template layer, so its column titles
// and cell labels come from ../typst/shared_strings.json — the same file the
// templates merge into their own strings. That is the one place those words
// live, and it is what stops a renamed state being spelled one way in the PDF
// and another in the CSV OF THE SAME EXPORT.
//
// ── Period ─────────────────────────────────────────────────────────────────
//
// `?year=` selects the visits MADE in that calendar year, `?month=` narrows it,
// neither reports everything on record. The boundaries are the CALLER's
// midnight, resolved from `?tzOffsetMinutes=` (goja has no Intl, so a zone name
// cannot be resolved server-side) — the same resolution the statistics route
// buckets with, which is what makes a New Year's Eve visit land in one year in
// both documents.
routerAdd(
  "GET",
  "/api/eiermann/reports/period",
  (e) => {
    // Required INSIDE the handler, absolute `${__hooks}` form: a file-level
    // binding is not visible here and fails as a generic 400 at request time.
    const stats = require(`${__hooks}/app_stats.js`);

    // The gate, from the one place that states it (app_auth.js): an active
    // caller whose role is NAMED. `role != null` is satisfied by `guest`, and a
    // route that checks only for one hands every stranger the identity provider
    // authenticated a complete export of the organisation's addresses.
    const { org } = require(`${__hooks}/app_auth.js`).requireMember(e);

    const query = e.request.url.query();
    // `.get()` yields "" (not null) for an absent param — the convention every
    // route here follows.
    const langParam = query.get("lang");
    const lang = langParam === "en" ? "en" : "de";

    const formatParam = query.get("format");
    if (
      formatParam &&
      formatParam !== "pdf" &&
      formatParam !== "summary" &&
      formatParam !== "csv"
    ) {
      const { refuse, CODES } = require(`${__hooks}/app_refuse.js`);
      refuse(
        CODES.reportFormatInvalid,
        'format must be "pdf", "summary" or "csv"',
      );
    }
    const format = formatParam || "pdf";

    const period = stats.parsePeriod(query);
    const year = period.year;
    const t = require(`${__hooks}/zv_time.js`).timeContext(query);
    const partsOf = t.partsOf;
    // Half-open, resolved through the caller's own offset; null for an all-time
    // report.
    const bounds = stats.periodBounds(period, t);

    // Sortable and unambiguous in a downloads folder: 2026, or 2026-03. ASCII
    // only — a Content-Disposition filename crosses the wire as a header, and a
    // German word with an umlaut in it arrives mangled or dropped depending on
    // the client.
    const periodSlug =
      year === null
        ? lang === "en"
          ? "all-time"
          : "gesamt"
        : period.month === null
          ? String(year)
          : year + "-" + (period.month < 10 ? "0" : "") + period.month;
    const baseName =
      (format === "summary"
        ? lang === "en"
          ? "eiermann-overview-"
          : "eiermann-uebersicht-"
        : lang === "en"
          ? "eiermann-report-"
          : "eiermann-bericht-") + periodSlug;

    // The table: one row per visit off `visit_rows`. Its columns ARE the report,
    // and nothing below adds or renames one.
    const rows = stats.loadVisitRows(e.app, org, bounds, t);

    // ── CSV ────────────────────────────────────────────────────────────────
    if (format === "csv") {
      // Column titles and the enum maps come from the file the templates read,
      // so the spreadsheet and the PDF cannot word the same cell differently. A
      // missing or corrupt file is a hard failure rather than a silent fall back
      // to wire values: a Behörde reading `not_reachable` is a worse outcome
      // than a 500 the operator can act on.
      let shared;
      try {
        shared = JSON.parse(
          toString($os.readFile("/pb/typst/shared_strings.json")),
        );
      } catch (err) {
        e.app
          .logger()
          .error("report: shared_strings.json unreadable", "error", String(err));
        return e.json(500, { error: "Report generation failed." });
      }
      const S = shared[lang] || shared.de;
      if (
        !S ||
        !S.reportColumns ||
        !S.visitOutcome ||
        !S.skipReason ||
        !S.findingKind
      ) {
        e.app.logger().error("report: shared_strings.json is missing keys");
        return e.json(500, { error: "Report generation failed." });
      }
      const C = S.reportColumns;

      // An enum value this build does not map is printed as its WIRE value — the
      // same stance Typst's `lbl` takes and the same one the app's own enum
      // readers take. An unknown enum is not something to guess at, and blanking
      // the cell loses the only information there was.
      const label = (map, wire) => (wire ? map[wire] || wire : "");
      const isoDate = (value) => {
        const p = partsOf(value);
        if (p === null) return "";
        const two = (n) => (n < 10 ? "0" + n : String(n));
        return p.y + "-" + two(p.mo) + "-" + two(p.d);
      };

      // Neutralises spreadsheet formula injection (OWASP CSV Injection). The
      // street, city, Spot name, note and author cells are all user-authored,
      // and Excel/LibreOffice EXECUTE a cell beginning with `=`, `+`, `-`, `@`,
      // tab or CR. A leading apostrophe forces text; RFC 4180 quoting alone does
      // not prevent it — the quotes are stripped before the formula parser sees
      // the cell.
      const DANGEROUS = ["=", "+", "-", "@", "\t", "\r"];
      const cell = (value) => {
        let s = value === null || value === undefined ? "" : String(value);
        if (s !== "" && DANGEROUS.indexOf(s.charAt(0)) !== -1) s = "'" + s;
        if (
          s.indexOf('"') !== -1 ||
          s.indexOf(",") !== -1 ||
          s.indexOf("\n") !== -1 ||
          s.indexOf("\r") !== -1
        ) {
          s = '"' + s.split('"').join('""') + '"';
        }
        return s;
      };

      const lines = [
        [
          C.street,
          C.postalCode,
          C.city,
          C.spotName,
          C.date,
          C.outcome,
          C.skipReason,
          C.checks,
          C.swapped,
          C.partial,
          C.empty,
          C.untouched,
          C.notReachable,
          C.gone,
          C.protectedState,
          C.removed,
          C.dummies,
          C.findings,
          C.findingKinds,
          C.note,
          C.author,
        ]
          .map(cell)
          .join(","),
      ];
      for (const r of rows) {
        // The joined kinds cell, split and translated one by one. Joined with
        // ", " on the way back out, not "; ": the wire form's separator is what
        // the split relies on, and re-emitting it would invite a consumer to
        // split a translated cell that may itself contain a semicolon.
        const kinds = r.findingsText
          ? r.findingsText
              .split("; ")
              .map((k) => label(S.findingKind, k.trim()))
              .join(", ")
          : "";
        lines.push(
          [
            r.street,
            r.postalCode,
            r.city,
            r.spotName,
            isoDate(r.visitedAt),
            label(S.visitOutcome, r.outcome),
            label(S.skipReason, r.skipReason),
            String(r.checksTotal),
            String(r.swapped),
            String(r.partial),
            String(r.empty),
            String(r.untouched),
            String(r.notReachable),
            String(r.gone),
            String(r.protectedChecks),
            String(r.removedReal),
            String(r.addedDummy),
            String(r.findingsTotal),
            kinds,
            r.note,
            r.authorName,
          ]
            .map(cell)
            .join(","),
        );
      }
      // CRLF, per RFC 4180.
      const text = lines.join("\r\n") + "\r\n";

      // UTF-8 encoded by hand rather than trusting the host's JS-string →
      // []byte conversion: a German report is full of umlauts and a street name
      // is exactly where that shows up, in the finished spreadsheet, after the
      // export was already sent. The leading EF BB BF is the BOM spreadsheet
      // apps need to read the file as UTF-8 at all.
      const bytes = [0xef, 0xbb, 0xbf];
      for (let i = 0; i < text.length; i++) {
        let cp = text.charCodeAt(i);
        if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < text.length) {
          const low = text.charCodeAt(i + 1);
          if (low >= 0xdc00 && low <= 0xdfff) {
            cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
            i++;
          }
        }
        if (cp < 0x80) {
          bytes.push(cp);
        } else if (cp < 0x800) {
          bytes.push(0xc0 | (cp >> 6), 0x80 | (cp & 0x3f));
        } else if (cp < 0x10000) {
          bytes.push(
            0xe0 | (cp >> 12),
            0x80 | ((cp >> 6) & 0x3f),
            0x80 | (cp & 0x3f),
          );
        } else {
          bytes.push(
            0xf0 | (cp >> 18),
            0x80 | ((cp >> 12) & 0x3f),
            0x80 | ((cp >> 6) & 0x3f),
            0x80 | (cp & 0x3f),
          );
        }
      }

      // An export is data LEAVING the system, and the one READ in this app
      // worth a row — everything else in the log is a write. eiermann-30w.6,
      // closing eiermann-ycd.
      //
      // Both successful paths emit, because both hand somebody a file: this
      // one and the PDF below, which `format=summary` shares. Emitted at the
      // END of each, so a request that failed to render does not claim a
      // report went out the door — the two 500s above return before here.
      require(`${__hooks}/app_audit_log.js`).emit(
        e,
        require(`${__hooks}/app_audit_log.js`).ACTIONS.REPORT_EXPORTED,
        { org: org, detail: { format: format, period: periodSlug } },
      );
      e.response
        .header()
        .set(
          "Content-Disposition",
          'attachment; filename="' + baseName + '.csv"',
        );
      return e.blob(200, "text/csv; charset=utf-8", new Uint8Array(bytes));
    }

    // ── The PDF payload ────────────────────────────────────────────────────
    // Both templates read the same payload; the summary simply ignores the
    // per-address detail. One shape, because two would be two things to keep in
    // step for no gain — and because a reader comparing the two documents is
    // comparing figures that came out of the same object.
    const agg = stats.aggregate(rows, { t: t, period: period });

    let orgRec = null;
    try {
      orgRec = e.app.findRecordById("organisations", org);
    } catch (_) {
      // An account whose org row vanished still gets a report, just an unnamed
      // one. Refusing here would withhold the document over the one field that
      // is decoration.
    }

    const standing = stats.spotStanding(e.app, org);
    const payload = {
      lang: lang,
      generatedAt: partsOf(new Date().toISOString()),
      org: {
        name: orgRec ? orgRec.getString("name") : "",
        contactEmail: orgRec ? orgRec.getString("contact_email") : "",
        contactPhone: orgRec ? orgRec.getString("contact_phone") : "",
      },
      period: {
        year: year,
        // Null for a whole year; the templates title the document differently
        // when a single month was asked for.
        month: period.month,
        from: bounds === null ? null : partsOf(t.pbStamp(bounds.fromMs)),
        // The INCLUSIVE last day, because that is what a reader expects printed
        // ("01.01. – 31.12."), while the filter above is a half-open range.
        to: bounds === null ? null : partsOf(t.pbStamp(bounds.toMs - 1)),
      },
      totals: agg.totals,
      checkStates: agg.checkStates,
      findingKinds: agg.findingKinds,
      findingSpecies: stats.findingSpecies(e.app, org, rows),
      skipReasons: agg.skipReasons,
      addresses: agg.addresses,
      bucketKind: agg.bucketKind,
      points: agg.points,
      // Standing figures, unaffected by the period above — the templates label
      // them as of today for exactly that reason.
      spots: {
        total: standing.total,
        phases: standing.phases,
        prospectStages: standing.prospectStages,
      },
      addressGroups: stats
        .groupByAddress(rows, { t: t, period: period })
        .map((group) => ({
          address: group.address,
          street: group.street,
          postalCode: group.postalCode,
          city: group.city,
          spotName: group.spotName,
          totals: group.totals,
          checkStates: group.checkStates,
          findingKinds: group.findingKinds,
          visits: group.rows.map((r) => ({
            date: partsOf(r.visitedAt),
            outcome: r.outcome || null,
            skipReason: r.skipReason || null,
            checks: r.checksTotal,
            swapped: r.swapped,
            partial: r.partial,
            empty: r.empty,
            untouched: r.untouched,
            notReachable: r.notReachable,
            gone: r.gone,
            protectedCount: r.protectedChecks,
            removed: r.removedReal,
            dummies: r.addedDummy,
            findings: r.findingsTotal,
            // Split here rather than in the template: the "; " separator is a
            // property of the view's GROUP_CONCAT, and a template should not
            // have to know it.
            findingKinds: r.findingsText
              ? r.findingsText.split("; ").map((k) => k.trim())
              : [],
            note: r.note,
            author: r.authorName,
          })),
        })),
    };

    // ── Render ─────────────────────────────────────────────────────────────
    // The payload goes to Typst as a FILE, not as `--input data=<the whole
    // JSON>`. An argv element has a hard ceiling (ARG_MAX, ~2 MB on Linux) and
    // this payload carries an entry per visit in the period with an unbounded
    // read behind it: a few thousand visits and the report stops rendering, with
    // an opaque exec error rather than anything a reader could act on. A path
    // also keeps the visit list out of the process table, where every account on
    // the host can read it out of `ps`.
    //
    // The temp file lives under the typst `--root` because a path outside /pb is
    // unreadable to Typst, and in /pb/report-tmp rather than the template
    // directory: that directory is static and baked, and writing into it would
    // make the image's contents depend on who asked for a report.
    const template = format === "summary" ? "summary.typ" : "report.typ";
    const stamp = Date.now() + "-" + Math.floor(Math.random() * 1e9);
    const dataDir = "/pb/report-tmp/" + format + "-" + periodSlug + "-" + stamp;
    const dataPath = dataDir + "/data.json";
    const outPath =
      $os.tempDir() + "/eiermann-" + format + "-" + periodSlug + "-" + stamp + ".pdf";
    try {
      $os.mkdirAll(dataDir, 0o755);
      $os.writeFile(dataPath, JSON.stringify(payload), 0o644);
      $os
        .cmd(
          "typst",
          "compile",
          "--root",
          "/pb",
          "--input",
          "dataPath=" + dataPath.slice("/pb".length),
          "/pb/typst/" + template,
          outPath,
        )
        .run();
    } catch (err) {
      e.app
        .logger()
        .error(
          "report: typst compile failed",
          "error",
          String(err),
          "format",
          format,
          "year",
          year,
        );
      return e.json(500, { error: "Report generation failed." });
    } finally {
      try {
        $os.removeAll(dataDir);
      } catch (_) {
        // best-effort cleanup
      }
    }

    let bytes;
    try {
      bytes = $os.readFile(outPath);
    } finally {
      try {
        $os.remove(outPath);
      } catch (_) {
        // best-effort cleanup
      }
    }

    // The second of the two export paths. See the CSV one above for why.
    require(`${__hooks}/app_audit_log.js`).emit(
      e,
      require(`${__hooks}/app_audit_log.js`).ACTIONS.REPORT_EXPORTED,
      { org: org, detail: { format: format, period: periodSlug } },
    );
    e.response
      .header()
      .set("Content-Disposition", 'attachment; filename="' + baseName + '.pdf"');
    return e.blob(200, "application/pdf", bytes);
  },
  $apis.requireAuth(),
);
