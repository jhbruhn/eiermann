import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/tours/tour_run_screen.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/harness.dart';

class _MockRuns extends Mock implements TourRunsRepository {}

class _MockStops extends Mock implements TourStopsRepository {}

class _MockVisitLog extends Mock implements VisitLogRepository {}

class _MockOverview extends Mock implements SpotOverviewRepository {}

SpotOverview _spot(String id, String name) =>
    SpotOverview(id: id, name: name, urgency: SpotUrgency.overdue.rank);

TourStop _stop(String id, String spot, int index) =>
    TourStop(id: id, tour: 't1', spot: spot, sortIndex: index);

void main() {
  late AppLocalizations de;
  late _MockRuns runs;
  late _MockStops stops;
  late _MockVisitLog visitLog;
  late _MockOverview overview;

  setUpAll(() async => de = await germanStrings());

  setUp(() {
    runs = _MockRuns();
    stops = _MockStops();
    visitLog = _MockVisitLog();
    overview = _MockOverview();
    when(() => overview.search(any())).thenAnswer(
      (_) async => [
        _spot('s1', 'Bahnhofstraße 12'),
        _spot('s2', 'Alter Speicher'),
      ],
    );
    when(() => stops.forTour(any())).thenAnswer((_) async => []);
    when(() => visitLog.forRun(any())).thenAnswer((_) async => []);
  });

  /// A tall surface. A `ListView` does not build what is below the fold, so on
  /// the default 800x600 the finish button vanishes the moment a third stop is
  /// inserted above it — and the test would read as "the control is missing".
  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpApp(
      const TourRunScreen(runId: 'r1'),
      overrides: [
        tourRunsRepositoryProvider.overrideWith((ref) async => runs),
        tourStopsRepositoryProvider.overrideWith((ref) async => stops),
        visitLogRepositoryProvider.overrideWith((ref) async => visitLog),
        spotOverviewRepositoryProvider.overrideWith((ref) async => overview),
      ],
    );
    await tester.pumpAndSettle();
  }

  void givenRun({String? tour, String name = 'Tour 1', DateTime? finishedAt}) {
    when(() => runs.getOne('r1', expand: any(named: 'expand'))).thenAnswer(
      (_) async => TourRun(
        id: 'r1',
        tour: tour,
        tourName: name,
        startedBy: 'u1',
        startedByName: 'Anke',
        startedAt: DateTime.utc(2026, 8, 21, 7),
        finishedAt: finishedAt,
      ),
    );
  }

  testWidgets('an untouched stop offers checking AND skipping, side by side', (
    tester,
  ) async {
    // The concept asks for this in as many words: both are outcomes, and
    // "nobody there" is a fact about the building rather than a failure of the
    // round. A skip buried in an overflow menu is one people record nowhere.
    givenRun(tour: 't1');
    when(
      () => stops.forTour('t1'),
    ).thenAnswer((_) async => [_stop('st1', 's1', 0)]);

    await pump(tester);

    expect(find.text('Bahnhofstraße 12'), findsOneWidget);
    expect(find.byTooltip(de.tourRunCheckAction), findsOneWidget);
    expect(find.byTooltip(de.tourRunSkipAction), findsOneWidget);
  });

  testWidgets('a skipped stop reads as settled, with its reason', (
    tester,
  ) async {
    givenRun(tour: 't1');
    when(
      () => stops.forTour('t1'),
    ).thenAnswer((_) async => [_stop('st1', 's1', 0)]);
    when(() => visitLog.forRun('r1')).thenAnswer(
      (_) async => [
        Visit(
          id: 'v1',
          spot: 's1',
          outcome: VisitOutcome.skipped,
          skipReason: SkipReason.noKey,
          visitedAt: DateTime.utc(2026, 8, 21, 8),
          tourRun: 'r1',
        ),
      ],
    );

    await pump(tester);

    expect(
      find.text(de.tourRunStopSkipped(de.skipReasonNoKey)),
      findsOneWidget,
    );
    // Settled: neither action is offered any more.
    expect(find.byTooltip(de.tourRunCheckAction), findsNothing);
    expect(find.byTooltip(de.tourRunSkipAction), findsNothing);
    expect(find.text(de.tourRunProgress(1, 1)), findsOneWidget);
  });

  testWidgets('a building the template never listed is marked as an addition', (
    tester,
  ) async {
    // Shown after the route rather than inside it: inserting it would claim the
    // template says something it does not.
    givenRun(tour: 't1');
    when(
      () => stops.forTour('t1'),
    ).thenAnswer((_) async => [_stop('st1', 's1', 0)]);
    when(() => visitLog.forRun('r1')).thenAnswer(
      (_) async => [
        Visit(
          id: 'v1',
          spot: 's2',
          outcome: VisitOutcome.checked,
          visitedAt: DateTime.utc(2026, 8, 21, 8),
          tourRun: 'r1',
        ),
      ],
    );

    await pump(tester);

    // The exact subtitle, not `textContaining`: the header's "1 Gebäude
    // zusätzlich" contains the same word, and a loose match would pass on
    // either one alone.
    expect(
      find.text('${de.tourRunAddedStop} · ${de.tourRunStopChecked}'),
      findsOneWidget,
    );
    // The addition does not make the planned route more finished.
    expect(find.text(de.tourRunProgress(0, 1)), findsOneWidget);
    expect(find.text(de.tourRunAdded(1)), findsOneWidget);
  });

  testWidgets('finishing early is offered, and says how much is left', (
    tester,
  ) async {
    // A disabled button would leave discarding as the only way out of a round
    // that cannot be completed today — and the visits already made deserve
    // better than that.
    givenRun(tour: 't1');
    when(
      () => stops.forTour('t1'),
    ).thenAnswer((_) async => [_stop('st1', 's1', 0), _stop('st2', 's2', 1)]);

    await pump(tester);

    expect(find.text(de.tourRunFinishAction), findsOneWidget);
    expect(find.text(de.tourRunFinishEarlyHint(2)), findsOneWidget);
  });

  testWidgets('a round with no template counts what was recorded, not "of"', (
    tester,
  ) async {
    // "3 von 7" is meaningless where there is no plan: every stop is an
    // addition, and the count of them is the whole story.
    givenRun(name: '');
    when(() => visitLog.forRun('r1')).thenAnswer(
      (_) async => [
        Visit(
          id: 'v1',
          spot: 's1',
          outcome: VisitOutcome.checked,
          visitedAt: DateTime.utc(2026, 8, 21, 8),
          tourRun: 'r1',
        ),
      ],
    );

    await pump(tester);

    expect(find.text(de.tourRunTitleAdHoc), findsOneWidget);
    expect(find.text(de.tourRunProgressAdHoc(1)), findsOneWidget);
    // The shortlist is the ad-hoc mode's plan substitute, and nothing about it
    // is stored.
    expect(find.text(de.tourNearbyTitle), findsOneWidget);
  });

  testWidgets('a round WITH a template gets no nearby shortlist', (
    tester,
  ) async {
    // The plan IS the list there; a second one underneath would compete with
    // the route somebody is walking.
    givenRun(tour: 't1');
    when(
      () => stops.forTour('t1'),
    ).thenAnswer((_) async => [_stop('st1', 's1', 0)]);

    await pump(tester);

    expect(find.text(de.tourNearbyTitle), findsNothing);
  });

  testWidgets('the nearby shortlist says which order it is in', (tester) async {
    // Without that line a list sorted by urgency looks like a distance list
    // that is simply wrong.
    givenRun(name: '');

    await pump(tester);

    expect(find.text(de.tourNearbyNoFix), findsOneWidget);
    expect(find.text(de.tourNearbyByDistance), findsNothing);
  });

  testWidgets('a finished round offers nothing to do and says it is over', (
    tester,
  ) async {
    givenRun(tour: 't1', finishedAt: DateTime.utc(2026, 8, 21, 12));
    when(
      () => stops.forTour('t1'),
    ).thenAnswer((_) async => [_stop('st1', 's1', 0)]);

    await pump(tester);

    expect(find.text(de.tourRunFinished), findsOneWidget);
    expect(find.text(de.tourRunFinishAction), findsNothing);
    expect(find.text(de.tourRunAddSpotAction), findsNothing);
    expect(find.byTooltip(de.tourRunCheckAction), findsNothing);
    // Nothing deletes a finished round — not even the coordination — so the
    // discard action is gone with it.
    expect(find.byTooltip(de.tourRunDiscardAction), findsNothing);
  });

  testWidgets('an empty round is an instruction, not an error', (tester) async {
    // An ad-hoc round starts empty BY DESIGN.
    givenRun(name: '');

    await pump(tester);

    expect(find.text(de.tourRunEmptyTitle), findsOneWidget);
  });
}
