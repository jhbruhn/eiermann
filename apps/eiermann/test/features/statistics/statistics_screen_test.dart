import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/statistics/period_selector.dart';
import 'package:eiermann/features/statistics/statistics_screen.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

import '../../support/harness.dart';

class _MockStats extends Mock implements StatsRepository {}

/// The figures as the server sends them, with the parts each test cares about
/// overridable.
OrgStatistics stats({
  int visits = 4,
  int visitsChecked = 3,
  int visitsSkipped = 1,
  int spotsVisited = 2,
  int checks = 7,
  int eggsRemoved = 6,
  int dummiesPlaced = 6,
  int findings = 2,
  double? accessRate = 0.75,
  double? fullSwapRate = 0.5,
  double? eggsPerCheckedVisit = 2,
  List<EnumCount<CheckState>>? checkStates,
  List<StatCount> findingSpecies = const [StatCount('Dohle', 1)],
  List<int> visitYears = const [2026, 2025],
  SpotStanding spots = const SpotStanding(
    total: 4,
    phases: [
      EnumCount(SpotPhase.active, 3),
      EnumCount(SpotPhase.prospect, 1),
    ],
    prospectStages: [EnumCount(ProspectStage.ownerSpoken, 1)],
  ),
}) => OrgStatistics(
  year: 2026,
  visits: visits,
  visitsChecked: visitsChecked,
  visitsSkipped: visitsSkipped,
  spotsVisited: spotsVisited,
  checks: checks,
  eggsRemoved: eggsRemoved,
  dummiesPlaced: dummiesPlaced,
  findings: findings,
  accessRate: accessRate,
  fullSwapRate: fullSwapRate,
  eggsPerCheckedVisit: eggsPerCheckedVisit,
  series: const VisitSeries(
    kind: SeriesBucket.month,
    points: [
      SeriesPoint(1),
      SeriesPoint(2, visits: 2, removed: 4, dummies: 4),
      SeriesPoint(3, visits: 2, removed: 2, dummies: 2),
    ],
    previousYear: 2025,
    previousPoints: [SeriesPoint(2, visits: 1, removed: 1, dummies: 1)],
  ),
  checkStates:
      checkStates ??
      const [
        EnumCount(CheckState.swapped, 2),
        EnumCount(CheckState.partial, 2),
        EnumCount(CheckState.empty, 3),
        EnumCount(CheckState.untouched, 0),
        EnumCount(CheckState.notReachable, 0),
        EnumCount(CheckState.gone, 0),
        EnumCount(CheckState.protected, 0),
      ],
  findingKinds: const [
    EnumCount(FindingKind.deadBird, 2),
  ],
  findingSpecies: findingSpecies,
  skipReasons: const [EnumCount(SkipReason.noKey, 1)],
  addresses: const [
    StatCount('Mühlenstraße 5, 26121 Oldenburg', 3),
    StatCount('Andere Allee 1', 1),
  ],
  visitYears: visitYears,
  spots: spots,
);

void main() {
  late AppLocalizations de;
  late _MockStats repo;

  setUpAll(() async {
    de = await germanStrings();
  });

  setUp(() {
    repo = _MockStats();
  });

  /// A TALL surface. A `ListView` does not build what is below the fold, so on
  /// the default 800x600 every card under the KPI grid is simply absent — and
  /// the test would read as "the breakdown is missing".
  Future<void> pump(WidgetTester tester, OrgStatistics figures) async {
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    when(
      () => repo.fetch(
        year: any(named: 'year'),
        month: any(named: 'month'),
        tzOffsetMinutes: any(named: 'tzOffsetMinutes'),
      ),
    ).thenAnswer((_) async => figures);

    await tester.pumpApp(
      const StatisticsScreen(),
      overrides: [
        statsRepositoryProvider.overrideWith((ref) async => repo),
      ],
    );
    await tester.pumpAndSettle();
  }

  /// The tile for [label], so an assertion cannot read the number out of a
  /// neighbouring tile.
  Finder tile(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(KpiCard));

  testWidgets('the figures arrive from the server, not from an aggregation', (
    tester,
  ) async {
    await pump(tester, stats());

    expect(find.text(de.statsTitle), findsOneWidget);
    expect(
      find.descendant(of: tile(de.statsVisits), matching: find.text('4')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tile(de.statsEggsRemoved), matching: find.text('6')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tile(de.statsChecks), matching: find.text('7')),
      findsOneWidget,
    );
    // One call, for the whole screen.
    verify(
      () => repo.fetch(
        year: any(named: 'year'),
        month: any(named: 'month'),
        tzOffsetMinutes: any(named: 'tzOffsetMinutes'),
      ),
    ).called(1);
  });

  testWidgets('a rate is a percent, with its denominator inside the tile', (
    tester,
  ) async {
    await pump(tester, stats());
    expect(
      find.descendant(
        of: tile(de.statsAccessRate),
        matching: find.text(de.statsPercentValue('75')),
      ),
      findsOneWidget,
    );
    // Its denominator: every trip made. A caption under the grid would qualify
    // every tile in it.
    expect(
      find.descendant(
        of: tile(de.statsAccessRate),
        matching: find.text(de.statsAccessRateNote(4)),
      ),
      findsOneWidget,
    );
    // The swap rate's denominator is the clutches ENCOUNTERED — swapped plus
    // half-swapped, four here — not the seven checks.
    expect(
      find.descendant(
        of: tile(de.statsFullSwapRate),
        matching: find.text(de.statsFullSwapRateNote(4)),
      ),
      findsOneWidget,
    );
  });

  testWidgets('an undefined rate is a dash, never 0 %', (tester) async {
    // Nothing has been attempted, which is not the same as having failed
    // everything. "0 %" would be a statement about the work.
    await pump(
      tester,
      stats(
        accessRate: null,
        fullSwapRate: null,
        eggsPerCheckedVisit: null,
      ),
    );
    expect(
      find.descendant(of: tile(de.statsAccessRate), matching: find.text('–')),
      findsOneWidget,
    );
    expect(find.text(de.statsPercentValue('0')), findsNothing);
    expect(find.text(de.statsChecksNoteNone), findsOneWidget);
  });

  testWidgets('the check-state census keeps its zeros and states its total', (
    tester,
  ) async {
    await pump(tester, stats());
    expect(find.text(de.statsCheckStatesTitle), findsOneWidget);
    // A state that did not happen is a reading, and dropping it would make the
    // rows stop summing to the total printed beneath them.
    expect(find.text(de.checkStateGone), findsOneWidget);
    expect(find.text(de.statsCheckStatesFootnote(7)), findsOneWidget);
  });

  testWidgets('the standing Spot figures say they are not the period', (
    tester,
  ) async {
    await pump(tester, stats());
    expect(find.text(de.statsSpotsTitle), findsOneWidget);
    // Without this line, picking 2024 would read as "we had four buildings in
    // 2024".
    expect(find.text(de.statsSpotsFootnote(4)), findsOneWidget);
  });

  testWidgets('a period with no visits says so, and still offers the export', (
    tester,
  ) async {
    // A page of zeros reads as a failure of the work. This is a statement about
    // the period — and "we could not get in all spring" is itself something an
    // authority is shown, so the export stays reachable.
    await pump(
      tester,
      stats(
        visits: 0,
        visitsChecked: 0,
        visitsSkipped: 0,
        spotsVisited: 0,
        checks: 0,
        eggsRemoved: 0,
        dummiesPlaced: 0,
        findings: 0,
        accessRate: null,
        fullSwapRate: null,
        eggsPerCheckedVisit: null,
      ),
    );
    expect(find.text(de.statsEmptyTitle), findsOneWidget);
    expect(find.byType(KpiCard), findsNothing);
    expect(find.text(de.statsExportAction), findsWidgets);
    // The standing figures survive the empty period: how far the group's access
    // reaches is true whether or not anybody went out.
    expect(find.text(de.statsSpotsTitle), findsOneWidget);
  });

  testWidgets('the period control offers the years actually on record', (
    tester,
  ) async {
    await pump(tester, stats(visitYears: [2026, 2025, 2021]));
    expect(find.byType(PeriodSelector), findsOneWidget);
    // A year outside the two the segmented control shows is offered behind the
    // picker rather than as a fixed "last ten years" range, which would invite
    // reporting on a year the group did not exist.
    expect(find.text(de.statsPeriodEarlierYears), findsOneWidget);
    expect(find.text(de.statsPeriodAllTime), findsOneWidget);
  });

  testWidgets('picking a period asks the server again, for that period', (
    tester,
  ) async {
    await pump(tester, stats());
    // Scoped to the control: the chart's legend names the comparison year too,
    // and a bare text finder would be ambiguous between the two.
    await tester.tap(
      find.descendant(
        of: find.byType(SegmentedButton<int?>),
        matching: find.text('${DateTime.now().year - 1}'),
      ),
    );
    await tester.pumpAndSettle();
    // The screen aggregates nothing, so a different period is a different
    // request — not a filter over rows already on the device.
    verify(
      () => repo.fetch(
        year: DateTime.now().year - 1,
        tzOffsetMinutes: any(named: 'tzOffsetMinutes'),
      ),
    ).called(1);
  });

  group('earlierReportYears', () {
    test('drops the two the control already shows, and keeps the rest', () {
      final now = DateTime(2026, 5);
      expect(earlierReportYears([2026, 2025, 2024, 2021], now), [2024, 2021]);
    });

    test('offers nothing when only the two recent years have visits', () {
      expect(earlierReportYears([2026, 2025], DateTime(2026, 5)), isEmpty);
    });

    test('a year with no visits is never offered', () {
      // There is nothing in it to report, and a picker that offers it produces
      // a confidently empty document.
      expect(
        earlierReportYears([2026, 2020], DateTime(2026, 5)),
        [2020],
        reason: '2021–2024 had no visits',
      );
    });
  });
}
