import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/routing/router.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/harness.dart';

class _MockTours extends Mock implements ToursRepository {}

class _MockStops extends Mock implements TourStopsRepository {}

class _MockRuns extends Mock implements TourRunsRepository {}

class _MockVisitLog extends Mock implements VisitLogRepository {}

class _MockOverview extends Mock implements SpotOverviewRepository {}

void main() {
  late AppLocalizations de;
  late _MockTours tours;
  late _MockStops stops;
  late _MockRuns runs;
  late _MockVisitLog visitLog;
  late _MockOverview overview;

  setUpAll(() async {
    de = await germanStrings();
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() {
    tours = _MockTours();
    stops = _MockStops();
    runs = _MockRuns();
    visitLog = _MockVisitLog();
    overview = _MockOverview();
    // The run screen is a real route now, so a navigation lands on something
    // that reads.
    when(() => visitLog.forRun(any())).thenAnswer((_) async => []);
    when(() => overview.search(any())).thenAnswer((_) async => []);
    when(() => tours.all()).thenAnswer((_) async => []);
    when(() => stops.forTour(any())).thenAnswer((_) async => []);
    when(() => runs.openFor(any())).thenAnswer((_) async => null);
  });

  /// The REAL route table, not a bare `home:`. Starting a round navigates, and
  /// `startRun` resolves the router before its first await — the way every
  /// caller across an async gap has to. Without one in the tree it would throw
  /// before it got as far as saying anything, and the assertion below would be
  /// testing the absence of a router.
  ///
  /// A tall surface, because a `ListView` does not build what is below the
  /// fold: on the default 800x600 the improvised-round card disappears once a
  /// third template is added above it, and the test would read as "the control
  /// is missing".
  Future<void> pump(WidgetTester tester) async {
    tester.useSurface(const Size(1000, 3000));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          toursRepositoryProvider.overrideWith((ref) async => tours),
          tourStopsRepositoryProvider.overrideWith((ref) async => stops),
          tourRunsRepositoryProvider.overrideWith((ref) async => runs),
          visitLogRepositoryProvider.overrideWith((ref) async => visitLog),
          spotOverviewRepositoryProvider.overrideWith((ref) async => overview),
          currentUserProvider.overrideWith(
            (ref) async => const AppUser(
              id: 'u1',
              email: 'feld@eiermann.test',
              role: UserRole.member,
              org: 'org00000default',
            ),
          ),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('de'),
          routerConfig: GoRouter(
            routes: appRoutes(),
            initialLocation: Routes.tours,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('no template yet says WHY one exists', (tester) async {
    // The empty state names the painful handover — one of the three field
    // problems this app was built for — rather than describing the button.
    await pump(tester);

    expect(find.text(de.toursEmptyTitle), findsOneWidget);
    expect(find.text(de.toursEmptyMessage), findsOneWidget);
    // The improvised round is offered even with no template at all: it is not a
    // fallback for a missing one.
    expect(find.text(de.tourAdHocStartAction), findsOneWidget);
  });

  testWidgets('a template shows its stop count and can be started', (
    tester,
  ) async {
    when(() => tours.all()).thenAnswer(
      (_) async => [const Tour(id: 't1', name: 'Tour 1')],
    );
    when(() => stops.forTour('t1')).thenAnswer(
      (_) async => [
        const TourStop(id: 'st1', tour: 't1', spot: 's1'),
        const TourStop(id: 'st2', tour: 't1', spot: 's2'),
      ],
    );

    await pump(tester);

    expect(find.text('Tour 1'), findsOneWidget);
    expect(find.textContaining(de.tourStopCount(2)), findsOneWidget);
    expect(find.byTooltip(de.tourStartAction('Tour 1')), findsOneWidget);
  });

  testWidgets('an empty template can still be started', (tester) async {
    // Stops get added while walking — that is what "Spot ergänzen" is for — so
    // refusing here would make the empty template a dead end somebody has to
    // fill in before they may leave the house.
    when(() => tours.all()).thenAnswer(
      (_) async => [const Tour(id: 't1', name: 'Tour 1')],
    );

    await pump(tester);

    // By its icon, not through the tooltip: an IconButton builds its Tooltip
    // INSIDE itself, so `byTooltip` finds a descendant and casting that to an
    // IconButton is a type error rather than a finding.
    final start = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.play_arrow),
    );
    expect(start.onPressed, isNotNull);
  });

  testWidgets('a retired template is kept, in its own section', (tester) async {
    // The rounds walked under it are still in the history, so the route that
    // produced them stays readable.
    when(() => tours.all()).thenAnswer(
      (_) async => [
        const Tour(id: 't1', name: 'Aktuell'),
        const Tour(id: 't2', name: 'Ausgemustert', isActive: false),
      ],
    );

    await pump(tester);

    expect(find.text(de.toursRetiredTitle), findsOneWidget);
    expect(find.text('Ausgemustert'), findsOneWidget);
    // No start button on a retired route — it is out of use, not deleted.
    expect(find.byTooltip(de.tourStartAction('Ausgemustert')), findsNothing);
    expect(find.byTooltip(de.tourStartAction('Aktuell')), findsOneWidget);
  });

  testWidgets('the menu offers retiring, never deleting', (tester) async {
    // Deleting is the coordination's: it takes the stop list with it and
    // orphans every round ever walked under the route.
    when(() => tours.all()).thenAnswer(
      (_) async => [const Tour(id: 't1', name: 'Tour 1')],
    );
    when(() => tours.retire(any())).thenAnswer(
      (_) async => const Tour(id: 't1', name: 'Tour 1', isActive: false),
    );

    await pump(tester);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    expect(find.text(de.tourRetireAction), findsOneWidget);
    await tester.tap(find.text(de.tourRetireAction));
    await tester.pumpAndSettle();

    verify(() => tours.retire('t1')).called(1);
  });

  testWidgets('an open round is offered as "fortsetzen", above everything', (
    tester,
  ) async {
    // The open row on the SERVER is the resume point, which is what makes a
    // round survive the app being killed: there is no local draft to be missing
    // on another device.
    when(() => runs.openFor('u1')).thenAnswer(
      (_) async => TourRun(
        id: 'r1',
        tour: 't1',
        tourName: 'Tour 1',
        startedBy: 'u1',
        startedAt: DateTime.utc(2026, 8, 21, 7),
      ),
    );

    await pump(tester);

    expect(find.text(de.tourRunResume('Tour 1')), findsOneWidget);
  });

  testWidgets(
    'an open round with no template says so without inventing a name',
    (tester) async {
      when(() => runs.openFor('u1')).thenAnswer(
        (_) async => TourRun(
          id: 'r1',
          startedBy: 'u1',
          startedAt: DateTime.utc(2026, 8, 21, 7),
        ),
      );

      await pump(tester);

      expect(find.text(de.tourRunResumeAdHoc), findsOneWidget);
    },
  );

  testWidgets('no open round shows no card at all', (tester) async {
    await pump(tester);

    expect(find.text(de.tourRunResumeAdHoc), findsNothing);
    expect(find.textContaining('fortsetzen'), findsNothing);
  });

  testWidgets('starting a round while one is open goes to the open one', (
    tester,
  ) async {
    // Two open rounds for one person is a state nothing in the app wants:
    // visits would land in whichever one the screen happened to hold. An access
    // rule cannot count rows, so the client prevents it.
    when(() => runs.openFor('u1')).thenAnswer(
      (_) async => TourRun(
        id: 'r1',
        startedBy: 'u1',
        startedAt: DateTime.utc(2026, 8, 21, 7),
      ),
    );

    await pump(tester);
    await tester.tap(find.text(de.tourAdHocStartAction));
    await tester.pump();
    await tester.pump();

    expect(find.text(de.tourRunAlreadyOpen), findsOneWidget);
    verifyNever(() => runs.create(any()));
  });
}
