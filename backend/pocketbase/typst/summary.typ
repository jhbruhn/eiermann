// eiermann-fi2.5 — die Förderer-Zusammenfassung: the same period as report.typ,
// read by somebody deciding whether to keep funding it.
//
// Rendered server-side by pb_hooks/report.pb.js (`?format=summary`) from the
// SAME payload as the authority report, minus the per-visit detail. That is the
// point of one route and one aggregation: a funder and a Behörde reading the two
// documents side by side see the same figures, because there is one definition
// of each.
//
// ── What a funder is asking, and what this leaves out ──────────────────────
//
// Not "what happened at Musterstraße 5" but "what did this year of volunteer
// work amount to". So there is no visit table and no address detail beyond how
// often each building was looked after: a list of individual trips answers a
// question a funder did not ask, and its length hides the two figures they did.
//
// What is NOT left out is the shape of the year — the eggs-removed curve is the
// one thing that shows the work is continuous rather than a burst — and the
// standing Spot figures, which say how far the group's access reaches. Those are
// deliberately NOT period-scoped (see app_stats.js's spotStanding) and are
// labelled as of today, or a reader picking last year would read them as a
// historical figure.
//
// Nothing on this page is truncated. A breakdown with forty rows simply
// continues down its column and onto a second page: an org with forty species
// has forty species, and a "… und 12 weitere" line leaves the reader unable to
// tell whether the tail is twelve findings or a hundred.
#import "zv_report_common.typ": a4Report, fmtDate, fmtDateTime, lbl, resolveStrings

#let data = json(read(sys.inputs.dataPath, encoding: none))
#let lang = data.at("lang", default: "de")

#let SHARED = json("shared_strings.json")
#let STRINGS = (
  de: (
    title: "Jahresübersicht Gelegemanagement",
    titleMonth: "Übersicht Gelegemanagement",
    titleAllTime: "Übersicht Gelegemanagement — gesamter Zeitraum",
    periodLabel: "Zeitraum",
    periodAllTime: "alle erfassten Besuche",
    generatedAtLabel: "Erstellt am",
    pageLabel: "Seite",
    pageOfSep: "von",
    dateFmt: "[day].[month].[year]",
    dateTimeFmt: "[day].[month].[year], [hour]:[minute]",
    decimalSep: ",",
    empty: "Im gewählten Zeitraum ist kein Besuch erfasst.",
    emptySection: "keine Angaben",
    kpiVisits: "Besuche",
    kpiSpots: "betreute Gebäude",
    kpiRemoved: "Eier entnommen",
    kpiDummies: "Attrappen gelegt",
    kpiAccess: "Zugang erhalten",
    kpiSwap: "Gelege vollständig getauscht",
    sectionCurve: "Entnommene Eier im Zeitverlauf",
    sectionStates: "Ergebnisse der Nestkontrollen",
    sectionFindings: "Funde",
    sectionSpecies: "Artbezeichnungen",
    sectionSkips: "Gründe für nicht durchgeführte Kontrollen",
    sectionAddresses: "Besuche je Gebäude",
    sectionPhases: "Gebäude nach Status",
    sectionStages: "Erkundungen nach Stand",
    standingNote: "Stand heute, unabhängig vom gewählten Zeitraum.",
    curveLegend: (visits, checks) => (
      "Balken: entnommene Eier. Im Zeitraum " + str(visits) + " Besuche mit "
      + str(checks) + " Nestkontrollen."
    ),
    months: ("J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"),
    monthsLong: (
      "Januar", "Februar", "März", "April", "Mai", "Juni",
      "Juli", "August", "September", "Oktober", "November", "Dezember",
    ),
  ),
  en: (
    title: "Clutch management — annual overview",
    titleMonth: "Clutch management overview",
    titleAllTime: "Clutch management overview — all records",
    periodLabel: "Period",
    periodAllTime: "every recorded visit",
    generatedAtLabel: "Generated",
    pageLabel: "Page",
    pageOfSep: "of",
    dateFmt: "[year]-[month]-[day]",
    dateTimeFmt: "[year]-[month]-[day] [hour]:[minute]",
    decimalSep: ".",
    empty: "No visit is recorded for the selected period.",
    emptySection: "no entries",
    kpiVisits: "Visits",
    kpiSpots: "Buildings looked after",
    kpiRemoved: "Eggs removed",
    kpiDummies: "Dummies placed",
    kpiAccess: "Got in",
    kpiSwap: "Clutches fully swapped",
    sectionCurve: "Eggs removed over time",
    sectionStates: "Nest check outcomes",
    sectionFindings: "Findings",
    sectionSpecies: "Species recorded",
    sectionSkips: "Reasons a check did not happen",
    sectionAddresses: "Visits per building",
    sectionPhases: "Buildings by status",
    sectionStages: "Prospects by stage",
    standingNote: "As of today, regardless of the selected period.",
    curveLegend: (visits, checks) => (
      "Bars: eggs removed. " + str(visits) + " visits with " + str(checks)
      + " nest checks in the period."
    ),
    months: ("J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"),
    monthsLong: (
      "January", "February", "March", "April", "May", "June",
      "July", "August", "September", "October", "November", "December",
    ),
  ),
)
#let S = resolveStrings(STRINGS, SHARED, lang)

#let periodYear = data.period.at("year", default: none)
#let periodMonth = data.period.at("month", default: none)
#let docTitle = if periodYear == none {
  S.titleAllTime
} else if periodMonth == none {
  S.title + " " + str(periodYear)
} else {
  let monthName = S.monthsLong.at(periodMonth - 1, default: str(periodMonth))
  S.titleMonth + " " + monthName + " " + str(periodYear)
}
#let periodLine = if periodYear == none {
  S.periodAllTime
} else {
  fmtDate(S, data.period.at("from", default: none)) + " – " + fmtDate(S, data.period.at("to", default: none))
}

#set document(title: data.org.name + " — " + docTitle)
#show: doc => a4Report(S, docTitle, data.at("generatedAt", default: none), doc)
#set text(lang: lang)

#let sectionTitle(body) = block(below: 5pt)[
  #text(size: 10.5pt, weight: "bold", tracking: 0.4pt)[#upper(body)]
  #v(1pt)
  #line(length: 100%, stroke: 0.5pt + black)
]
#let muted(body) = text(fill: gray)[#body]

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
  ],
)
#v(6pt)
#line(length: 100%, stroke: 0.75pt + black)
#v(10pt)

#let t = data.totals
#if t.visits == 0 [
  #muted[#S.empty]
] else {
  // A share prints as a whole percent, or as an en dash when it is undefined —
  // NEVER as 0 %. A rate with no denominator is the absence of a measurement,
  // and printing zero would claim the team got in nowhere.
  let pct(value) = if value == none {
    "–"
  } else {
    str(calc.round(value * 100)) + " %"
  }
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
    kpi(S.kpiRemoved, str(t.removedReal)),
    kpi(S.kpiDummies, str(t.addedDummy)),
    kpi(S.kpiAccess, pct(t.at("accessRate", default: none))),
    kpi(S.kpiSwap, pct(t.at("fullSwapRate", default: none))),
  )

  // ── The curve ─────────────────────────────────────────────────────────────
  // Plain Typst rects, not a plotting package: one bar per bucket, and there is
  // nothing in that worth a dependency (the vendored QR package earns its place;
  // a rectangle does not).
  let points = data.at("points", default: ())
  let bucketKind = data.at("bucketKind", default: "month")
  v(14pt)
  sectionTitle(S.sectionCurve)
  let removed = points.map(p => p.removed)
  let peak = if removed.len() == 0 { 0 } else { calc.max(..removed) }
  let bucketLabel(key) = if bucketKind == "month" {
    S.months.at(key - 1, default: str(key))
  } else {
    str(key)
  }
  if peak == 0 [
    #muted[#S.emptySection]
  ] else {
    let barHeight = 2.4cm
    // An all-time overview can have as few as one bucket, and a bar filling
    // half the page reads as a design element rather than as a measurement — so
    // past a handful the bars share the width and below it they keep a fixed one.
    let barWidth = if points.len() > 8 { 55% } else { 1.2cm }
    grid(
      columns: points.len() * (1fr,),
      align: center + bottom,
      row-gutter: 3pt,
      ..points.map(p => [
        #text(size: 7pt, fill: gray)[#if p.removed > 0 [#p.removed]]
        #v(1.5pt)
        #rect(
          width: barWidth,
          height: barHeight * p.removed / peak,
          fill: luma(75),
          stroke: none,
        )
      ]),
      ..points.map(p => text(size: 7.5pt)[#bucketLabel(p.key)]),
    )
    v(3pt)
    text(size: 7.5pt, fill: gray)[#(S.curveLegend)(t.visits, t.checks)]
  }

  // ── Breakdowns ────────────────────────────────────────────────────────────
  // Two columns of STACKED sections, so the pair breaks as one and each side
  // continues where it left off. A 2×2 grid of individual sections was tried
  // first: the taller cell of a pair pushed the next pair down, and a long
  // list's continuation landed at the top of the next page beside an empty
  // column. The assignment is fixed rather than balanced by row count, so the
  // document has the same shape every year regardless of the data.
  let breakdown(rows, map: none, total: none) = {
    if rows.len() == 0 {
      return muted[#S.emptySection]
    }
    table(
      columns: (1fr, auto, auto),
      align: (left, right, right),
      stroke: none,
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
  let section(title, rows, map: none, total: none, footer: none) = {
    sectionTitle(title)
    breakdown(rows, map: map, total: total)
    if footer != none { footer }
    v(12pt)
  }

  let spots = data.at("spots", default: (total: 0, phases: (), prospectStages: ()))
  v(14pt)
  grid(
    columns: (1fr, 1fr),
    column-gutter: 18pt,
    [
      #section(S.sectionStates, data.at("checkStates", default: ()), map: S.checkState, total: t.checks)
      #section(S.sectionFindings, data.at("findingKinds", default: ()), map: S.findingKind, total: t.findings)
      #section(S.sectionSkips, data.at("skipReasons", default: ()), map: S.skipReason, total: t.visitsSkipped)
    ],
    [
      #section(S.sectionPhases, spots.at("phases", default: ()), map: S.spotPhase, total: spots.at("total", default: 0), footer: [
        #v(1pt)
        #text(size: 7.5pt, fill: gray)[#S.standingNote]
      ])
      #section(S.sectionStages, spots.at("prospectStages", default: ()), map: S.prospectStage)
      #section(S.sectionSpecies, data.at("findingSpecies", default: ()), total: t.findings)
      #section(S.sectionAddresses, data.at("addresses", default: ()), total: t.visits)
    ],
  )
}
