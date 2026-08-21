import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/spots/spots_screen.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/routing/router.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:mocktail/mocktail.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

import '../../support/harness.dart';

class _MockOverview extends Mock implements SpotOverviewRepository {}

class _MockSpots extends Mock implements SpotsRepository {}

class _MockContacts extends Mock implements SpotContactsRepository {}

class _MockAreas extends Mock implements AreasRepository {}

class _MockNestStates extends Mock implements NestStateRepository {}

SpotOverview row({
  required String id,
  required String name,
  int urgency = 3,
}) => SpotOverview(
  id: id,
  name: name,
  urgency: urgency,
  phase: SpotPhase.active,
  street: 'Bahnhofstraße 12',
  city: 'Oldenburg',
  geo: const GeoPoint(lat: 53.14, lon: 8.21),
  contactCount: 1,
);

void main() {
  late AppLocalizations de;
  late _MockOverview overview;
  late _MockSpots spots;
  late _MockContacts contacts;
  late _MockAreas areas;
  late _MockNestStates nestStates;

  setUpAll(() async {
    de = await germanStrings();
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() {
    overview = _MockOverview();
    spots = _MockSpots();
    contacts = _MockContacts();
    areas = _MockAreas();
    nestStates = _MockNestStates();
    when(() => nestStates.forSpot(any())).thenAnswer((_) async => []);
    when(() => contacts.forSpot(any())).thenAnswer((_) async => []);
    when(() => areas.forSpot(any())).thenAnswer((_) async => []);
    when(() => overview.search(any())).thenAnswer((_) async => []);
    when(
      () => overview.dueFirst(
        query: any(named: 'query'),
        urgency: any(named: 'urgency'),
        after: any(named: 'after'),
        perPage: any(named: 'perPage'),
      ),
    ).thenAnswer((_) async => const SpotOverviewPage(items: []));
  });

  /// Pumps the REAL route table — the shell, its three branches and the
  /// dossier over them — with the gate left out. What is under test is the
  /// wiring in `appRoutes()`, so a test that rebuilt those routes by hand would
  /// only be testing its own copy.
  Future<void> pumpShell(
    WidgetTester tester, {
    Size size = const Size(400, 800),
    String at = '/',
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          spotOverviewRepositoryProvider.overrideWith((ref) async => overview),
          spotsRepositoryProvider.overrideWith((ref) async => spots),
          spotContactsRepositoryProvider.overrideWith((ref) async => contacts),
          areasRepositoryProvider.overrideWith((ref) async => areas),
          nestStateRepositoryProvider.overrideWith((ref) async => nestStates),
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
          routerConfig: GoRouter(routes: appRoutes(), initialLocation: at),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The destination inside the bar or the rail, never the screen behind it:
  /// "Karte" is also the map's app-bar title, and a finder that matched both
  /// would tap whichever came first.
  Finder destination(String label) => find.descendant(
    of: find.byType(NavigationBar),
    matching: find.text(label),
  );

  Finder railDestination(String label) => find.descendant(
    of: find.byType(NavigationRail),
    matching: find.text(label),
  );

  testWidgets('a phone gets the bar along the bottom, not a rail', (
    tester,
  ) async {
    await pumpShell(tester);

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    for (final label in [de.navDashboard, de.navMap, de.navSpots]) {
      expect(destination(label), findsOneWidget);
    }
  });

  testWidgets('a wide window gets the rail instead, with the same three', (
    tester,
  ) async {
    await pumpShell(tester, size: const Size(1200, 900));

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    for (final label in [de.navDashboard, de.navMap, de.navSpots]) {
      expect(railDestination(label), findsOneWidget);
    }
  });

  testWidgets('the map is reachable without an app-bar icon', (tester) async {
    // The concept calls the map the entry point for every round. It used to
    // hang behind an icon on the dashboard, one level below the list.
    await pumpShell(tester);

    await tester.tap(destination(de.navMap));
    await tester.pumpAndSettle();

    expect(find.byType(FlutterMap), findsOneWidget);
  });

  testWidgets('the list is a destination of its own', (tester) async {
    await pumpShell(tester);

    await tester.tap(destination(de.navSpots));
    await tester.pumpAndSettle();

    expect(find.byType(SpotsScreen), findsOneWidget);
  });

  testWidgets('the map keeps its camera across a tab switch', (tester) async {
    // The trap this destination exists inside of: `SpotsMapScreen` applies
    // `initialCameraFit` once per State, so a map that got re-mounted on every
    // switch would yank a reader who had panned to one district back out to the
    // whole city. Asserted on the CAMERA rather than on State identity, because
    // the camera is what the reader sees.
    when(() => overview.search(any())).thenAnswer(
      (_) async => [row(id: 's1', name: 'Bahnhofstraße 12')],
    );
    await pumpShell(tester, at: '/map');
    final controller = tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!;
    // Moved by hand rather than by a drag: what the gesture flags allow is a
    // different question from whether the viewport survives.
    const elsewhere = LatLng(52.5, 13.4);
    controller.move(elsewhere, 14);
    await tester.pumpAndSettle();

    await tester.tap(destination(de.navSpots));
    await tester.pumpAndSettle();
    await tester.tap(destination(de.navMap));
    await tester.pumpAndSettle();

    final camera = tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .camera;
    expect(camera.center.latitude, closeTo(elsewhere.latitude, 0.001));
    expect(camera.center.longitude, closeTo(elsewhere.longitude, 0.001));
    expect(camera.zoom, 14);
  });

  testWidgets('the list keeps its scroll offset across a tab switch', (
    tester,
  ) async {
    when(
      () => overview.dueFirst(
        query: any(named: 'query'),
        urgency: any(named: 'urgency'),
        after: any(named: 'after'),
        perPage: any(named: 'perPage'),
      ),
    ).thenAnswer(
      (_) async => SpotOverviewPage(
        items: [
          for (var n = 0; n < 30; n++) row(id: 's$n', name: 'Haus $n'),
        ],
      ),
    );
    await pumpShell(tester, at: '/spots');
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    final scrolled = tester.state<ScrollableState>(
      find.byType(Scrollable).last,
    );
    final offset = scrolled.position.pixels;
    expect(offset, greaterThan(0), reason: 'the drag has to have moved it');

    await tester.tap(destination(de.navDashboard));
    await tester.pumpAndSettle();
    await tester.tap(destination(de.navSpots));
    await tester.pumpAndSettle();

    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable).last)
          .position
          .pixels,
      offset,
    );
  });

  testWidgets('re-tapping the active tab drops the urgency filter', (
    tester,
  ) async {
    // The filter lives in the location, so returning the branch to its root IS
    // clearing it — and re-tapping the tab is what a reader tries anyway.
    await pumpShell(tester, at: '/spots?urgency=0');
    expect(find.text(de.spotUrgencyOverdue), findsOneWidget);

    await tester.tap(destination(de.navSpots));
    await tester.pumpAndSettle();

    expect(find.text(de.spotUrgencyOverdue), findsNothing);
    expect(find.byType(SpotsScreen), findsOneWidget);
  });

  testWidgets('dismissing the chip returns to the whole list', (tester) async {
    // The chip is the other way out of a filter, and it has to land on the same
    // location the tab does — the filter lives in the URL, so clearing it is a
    // navigation.
    await pumpShell(tester, at: '/spots?urgency=0');

    await tester.tap(find.byTooltip(de.spotsFilterClear));
    await tester.pumpAndSettle();

    expect(find.byType(InputChip), findsNothing);
    expect(find.byType(SpotsScreen), findsOneWidget);
  });

  testWidgets('a dashboard tile opens the list narrowed to its rank', (
    tester,
  ) async {
    when(() => overview.search(any())).thenAnswer(
      (_) async => [
        row(id: 's1', name: 'Bahnhofstraße 12', urgency: 0),
        row(id: 's2', name: 'Alter Speicher', urgency: 0),
        row(id: 's3', name: 'Im Rhythmus'),
      ],
    );
    await pumpShell(tester);

    await tester.tap(find.text('2'));
    await tester.pumpAndSettle();

    expect(find.byType(SpotsScreen), findsOneWidget);
    // The chip names the rank the list is narrowed to, and the query the
    // server was actually asked for carries the same rank.
    expect(find.text(de.spotUrgencyOverdue), findsWidgets);
    verify(
      () => overview.dueFirst(
        query: any(named: 'query'),
        urgency: SpotUrgency.overdue.rank,
        after: any(named: 'after'),
        perPage: any(named: 'perPage'),
      ),
    ).called(greaterThanOrEqualTo(1));
  });

  testWidgets('the dossier covers the shell rather than living in a branch', (
    tester,
  ) async {
    // No branch can be parked on a detail, which is why nothing here has to
    // hide the bar or reset a stale stack. See NavShell's doc. Asserted on a
    // WIDE window because that is where it would show: a detail inside a branch
    // would keep the rail beside it, and the rail is exactly what this design
    // trades away.
    when(
      () => spots.getOne(any()),
    ).thenAnswer((_) async => const Spot(id: 's1', name: 'Bahnhofstraße 12'));
    await pumpShell(tester, at: '/spots/s1', size: const Size(1200, 900));

    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
  });
}
