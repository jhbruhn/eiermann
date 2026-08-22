// eiermann-fi2.5 — der Behördenbericht: what was done, at which address, when.
//
// Rendered server-side by pb_hooks/report.pb.js via
// `typst compile --root /pb --input dataPath=<file> report.typ out.pdf`.
// The hook sends structured, UNTRANSLATED data — wire enum values, raw date
// parts, DB-authored labels — and every piece of localization happens here or
// in shared_strings.json. That split is what lets the CSV of the same export
// print the same words: see zv_report_common.typ's header.
//
// ── Who this document is for ────────────────────────────────────────────────
//
// A Behörde granting or renewing a permission, asking one question: what
// happened at this address? So the spine of the report is the ADDRESS, and
// under each one every visit in the period, in date order — including the ones
// where nobody got in. A trip that failed is what an application for a key is
// argued with, and leaving it out would make the building look unvisited.
//
// The per-address figures come from the same aggregation as the header's
// (app_stats.js), so the sections add up to the summary. Nothing is truncated
// and nothing is capped: an org with sixty buildings has sixty sections, and a
// reader must never be left wondering whether the tail they cannot see is two
// visits or twenty.
#import "zv_report_common.typ": a4Report, fmtDate, fmtDateTime, joinDot, lbl, resolveStrings

// The payload arrives as a FILE under the typst --root, never as an --input
// string: an argv element is size-capped (ARG_MAX) and world-readable in the
// process table, and this payload carries one entry per visit in the period.
// `read(..., encoding: none)` yields raw bytes, which is what json() wants.
#let data = json(read(sys.inputs.dataPath, encoding: none))
#let lang = data.at("lang", default: "de")

#let SHARED = json("shared_strings.json")
#let STRINGS = (
  de: (
    title: "Bericht zur Gelegekontrolle",
    titleAllTime: "Bericht zur Gelegekontrolle — gesamter Zeitraum",
    periodLabel: "Zeitraum",
    periodAllTime: "alle erfassten Besuche",
    generatedAtLabel: "Erstellt am",
    pageLabel: "Seite",
    pageOfSep: "von",
    dateFmt: "[day].[month].[year]",
    dateTimeFmt: "[day].[month].[year], [hour]:[minute]",
    decimalSep: ",",
    basisNote: (
      "Grundlage ist das Datum des Besuchs. Ein Besuch, bei dem niemand "
      + "angetroffen wurde, ist mit seinem Grund aufgeführt: er ist Teil der "
      + "Betreuung und wird nicht als Kontrolle gezählt."
    ),
    empty: "Im gewählten Zeitraum ist kein Besuch erfasst.",
    emptySection: "keine Angaben",
    kpiVisits: "Besuche",
    kpiSpots: "Gebäude",
    kpiChecks: "Nestkontrollen",
    kpiRemoved: "Eier entnommen",
    kpiDummies: "Attrappen gelegt",
    kpiFindings: "Funde",
    sectionAddresses: "Besuche je Adresse",
    sectionStates: "Ergebnisse der Nestkontrollen",
    sectionFindings: "Funde",
    sectionSpecies: "Artbezeichnungen",
    sectionSkips: "Gründe für nicht durchgeführte Kontrollen",
    total: "Summe",
    perAddress: (visits, checks) => (
      str(visits) + " Besuche · " + str(checks) + " Nestkontrollen"
    ),
    countVisits: n => if n == 1 { "1 Besuch" } else { str(n) + " Besuche" },
    months: (
      "Januar", "Februar", "März", "April", "Mai", "Juni",
      "Juli", "August", "September", "Oktober", "November", "Dezember",
    ),
  ),
  en: (
    title: "Clutch management report",
    titleAllTime: "Clutch management report — all records",
    periodLabel: "Period",
    periodAllTime: "every recorded visit",
    generatedAtLabel: "Generated",
    pageLabel: "Page",
    pageOfSep: "of",
    dateFmt: "[year]-[month]-[day]",
    dateTimeFmt: "[year]-[month]-[day] [hour]:[minute]",
    decimalSep: ".",
    basisNote: (
      "Visits are counted by the date of the visit. A visit where nobody was "
      + "there is listed with its reason: it is part of the work and is not "
      + "counted as a check."
    ),
    empty: "No visit is recorded for the selected period.",
    emptySection: "no entries",
    kpiVisits: "Visits",
    kpiSpots: "Buildings",
    kpiChecks: "Nest checks",
    kpiRemoved: "Eggs removed",
    kpiDummies: "Dummies placed",
    kpiFindings: "Findings",
    sectionAddresses: "Visits by address",
    sectionStates: "Nest check outcomes",
    sectionFindings: "Findings",
    sectionSpecies: "Species recorded",
    sectionSkips: "Reasons a check did not happen",
    total: "Total",
    perAddress: (visits, checks) => (
      str(visits) + " visits · " + str(checks) + " nest checks"
    ),
    countVisits: n => if n == 1 { "1 visit" } else { str(n) + " visits" },
    months: (
      "January", "February", "March", "April", "May", "June",
      "July", "August", "September", "October", "November", "December",
    ),
  ),
)
#let S = resolveStrings(STRINGS, SHARED, lang)
#let COLS = S.reportColumns

// ── Title and period ────────────────────────────────────────────────────────
#let periodYear = data.period.at("year", default: none)
#let periodMonth = data.period.at("month", default: none)
// One complete expression per line: at the top level of a markup file a `#let`
// ENDS at the line break, so a trailing operator makes Typst read the
// continuation as markup and typeset it — which is how the source of a
// `.filter(...)` chain once printed above a federfall report's header.
#let docTitle = if periodYear == none {
  S.titleAllTime
} else if periodMonth == none {
  S.title + " " + str(periodYear)
} else {
  let monthName = S.months.at(periodMonth - 1, default: str(periodMonth))
  S.title + " " + monthName + " " + str(periodYear)
}
#let periodLine = if periodYear == none {
  S.periodAllTime
} else {
  fmtDate(S, data.period.at("from", default: none)) + " – " + fmtDate(S, data.period.at("to", default: none))
}

#set document(title: data.org.name + " — " + docTitle)
// The shared page furniture: A4, margins, the serif face, and the footer with
// the reference on the left, the generation date in the middle and "page x of
// y" on the right. Applied as a SHOW rule and not called as a function: a `set`
// rule inside a plain function body applies only within that block, so the
// version that does not take the document body compiles cleanly and styles
// nothing at all.
#show: doc => a4Report(S, docTitle, data.at("generatedAt", default: none), doc)
#set text(lang: lang)

#let sectionTitle(body) = block(below: 5pt)[
  #text(size: 10.5pt, weight: "bold", tracking: 0.4pt)[#upper(body)]
  #v(1pt)
  #line(length: 100%, stroke: 0.5pt + black)
]
#let muted(body) = text(fill: gray)[#body]

#let orgContact = (
  (
    data.org.at("contactEmail", default: none),
    data.org.at("contactPhone", default: none),
  ).filter(v => v != none and v != "").join(" · ")
)

#grid(
  columns: (1fr, auto),
  align: (left + top, right + top),
  [
    #text(size: 11pt)[#data.org.name]
    #v(2pt)
    #text(size: 18pt, weight: "bold")[#docTitle]
    #v(3pt)
    #text(size: 10pt)[#S.periodLabel: #periodLine]
  ],
  [
    #set text(size: 8.5pt, fill: gray)
    #S.generatedAtLabel #fmtDateTime(S, data.at("generatedAt", default: none))
    #if orgContact != "" [ \ #orgContact ]
  ],
)
#v(6pt)
#line(length: 100%, stroke: 0.75pt + black)
#v(10pt)

#let groups = data.at("addressGroups", default: ())
#if groups.len() == 0 [
  // Say so and stop, rather than printing pages of zeros. A report full of
  // noughts looks like a failure of the work; this is a statement about the
  // period.
  #muted[#S.empty]
] else {
  let t = data.totals

  // ── Summary band ──────────────────────────────────────────────────────────
  let kpi(label, value) = block(
    width: 100%,
    inset: (x: 6pt, y: 7pt),
    radius: 3pt,
    stroke: 0.5pt + luma(150),
    align(center)[
      #text(size: 15pt, weight: "bold")[#value]
      #v(1pt)
      #text(size: 7.5pt, fill: gray)[#label]
    ],
  )
  grid(
    columns: (1fr, 1fr, 1fr, 1fr, 1fr, 1fr),
    column-gutter: 5pt,
    kpi(S.kpiVisits, str(t.visits)),
    kpi(S.kpiSpots, str(t.spotsVisited)),
    kpi(S.kpiChecks, str(t.checks)),
    kpi(S.kpiRemoved, str(t.removedReal)),
    kpi(S.kpiDummies, str(t.addedDummy)),
    kpi(S.kpiFindings, str(t.findings)),
  )
  v(4pt)
  text(size: 7.5pt, fill: gray)[#S.basisNote]
  v(12pt)

  // ── The breakdowns ────────────────────────────────────────────────────────
  // One shared shape for every label→count list. Every row is printed: the
  // check-state census IS the report for a permitting authority, and a capped
  // list with a "… und 9 weitere" line leaves the reader unable to tell whether
  // the tail is nine checks or ninety. The table breaks across pages by itself.
  let breakdown(rows, map: none, total: none) = {
    if rows.len() == 0 {
      return muted[#S.emptySection]
    }
    table(
      columns: (1fr, auto, auto),
      align: (left, right, right),
      stroke: none,
      // The count and its share need air between them, or "32" and "23 %" read
      // as one number.
      inset: (x, y) => (left: if x == 0 { 2pt } else { 8pt }, right: 2pt, y: 2.6pt),
      ..rows.map(r => (
        text(size: 9pt)[#if map == none { r.label } else { lbl(map, r.label) }],
        text(size: 9pt)[#r.count],
        if total == none or total == 0 {
          []
        } else {
          text(size: 8.5pt, fill: gray)[#str(calc.round(r.count / total * 100)) %]
        },
      )).flatten(),
    )
  }
  let section(title, rows, map: none, total: none) = {
    sectionTitle(title)
    breakdown(rows, map: map, total: total)
    v(12pt)
  }

  grid(
    columns: (1fr, 1fr),
    column-gutter: 18pt,
    [
      #section(S.sectionStates, data.at("checkStates", default: ()), map: S.checkState, total: t.checks)
      #section(S.sectionSkips, data.at("skipReasons", default: ()), map: S.skipReason, total: t.visitsSkipped)
    ],
    [
      #section(S.sectionFindings, data.at("findingKinds", default: ()), map: S.findingKind, total: t.findings)
      #section(S.sectionSpecies, data.at("findingSpecies", default: ()), total: t.findings)
    ],
  )

  // ── Per address ───────────────────────────────────────────────────────────
  sectionTitle(S.sectionAddresses)
  v(2pt)
  let head(body) = text(size: 8pt, weight: "bold")[#body]
  let cell(value) = text(size: 8pt)[#if value == none or value == "" [] else [#value]]
  for group in groups {
    // Kept together with its first rows, so an address heading is never the
    // last thing on a page with its table overleaf.
    block(breakable: false, above: 10pt, below: 4pt)[
      #text(size: 11pt, weight: "bold")[#group.address]
      #v(1pt)
      #text(size: 8.5pt, fill: gray)[
        #(S.perAddress)(group.totals.visits, group.totals.checks)
      ]
    ]
    // The visit table. Every text cell is user-authored and can be arbitrarily
    // long; a single long word does not wrap on its own and would print on top
    // of the next column, so hyphenation is on for the free-text ones.
    set text(hyphenate: true)
    table(
      columns: (auto, auto, auto, auto, auto, auto, auto, auto, 1fr),
      align: (left, left, right, right, right, right, right, right, left),
      stroke: (x, y) => if y == 0 {
        (bottom: 0.75pt + black)
      } else {
        (bottom: 0.25pt + luma(200))
      },
      inset: (x: 3pt, y: 3.5pt),
      table.header(
        head(COLS.date),
        head(COLS.outcome),
        head(COLS.checks),
        head(COLS.swapped),
        head(COLS.partial),
        head(COLS.empty),
        head(COLS.removed),
        head(COLS.dummies),
        head(COLS.findings),
      ),
      ..group.visits.map(v => (
        fmtDate(S, v.at("date", default: none)),
        // A skipped visit prints its REASON in the outcome column rather than
        // the word "Nicht geprüft" followed by an empty cell: the reason is the
        // information, and a Behörde reading "Kein Schlüssel" three times in a
        // row is reading the argument for a key.
        if v.at("outcome", default: "") == "skipped" {
          joinDot((
            lbl(S.visitOutcome, "skipped"),
            lbl(S.skipReason, v.at("skipReason", default: none)),
          ))
        } else {
          lbl(S.visitOutcome, v.at("outcome", default: none))
        },
        str(v.at("checks", default: 0)),
        str(v.at("swapped", default: 0)),
        str(v.at("partial", default: 0)),
        str(v.at("empty", default: 0)),
        str(v.at("removed", default: 0)),
        str(v.at("dummies", default: 0)),
        // The findings of that trip, by kind. Free-text species labels are
        // deliberately not folded in here — they are in their own section
        // above, where a long name has the width to be read.
        v.at("findingKinds", default: ())
          .map(k => lbl(S.findingKind, k))
          .join(", "),
      )).flatten().map(cell),
    )
  }
}
