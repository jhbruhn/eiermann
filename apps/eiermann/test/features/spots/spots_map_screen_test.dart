import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/spots/spots_map_screen.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

import '../../support/harness.dart';

class _MockOverview extends Mock implements SpotOverviewRepository {}

class _MockSpots extends Mock implements SpotsRepository {}

/// A row with everything the map draws, so each test only names its own
/// difference.
SpotOverview row({
  required String id,
  required String name,
  // Deliberately not a round number any test also passes explicitly: in the
  // clustering tests the coordinates ARE the subject, and spelling them out
  // must not read as redundant.
  double lat = 53.5,
  double lon = 8.5,
  int urgency = 3,
  bool pinned = true,
  bool geoConfirmed = true,
  SpotPhase phase = SpotPhase.active,
  int contactCount = 1,
  DateTime? nextDueAt,
}) => SpotOverview(
  id: id,
  name: name,
  street: 'Bahnhofstraße 12',
  city: 'Oldenburg',
  geo: pinned ? GeoPoint(lat: lat, lon: lon) : null,
  geoConfirmed: geoConfirmed,
  phase: phase,
  urgency: urgency,
  contactCount: contactCount,
  nextDueAt: nextDueAt,
);

void main() {
  late AppLocalizations de;
  late _MockOverview overview;
  late _MockSpots spots;

  setUpAll(() async {
    de = await germanStrings();
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() {
    overview = _MockOverview();
    spots = _MockSpots();
    when(() => spots.create(any())).thenAnswer(
      (_) async => const Spot(id: 's-new', name: 'Neu'),
    );
  });

  Future<void> pumpMap(WidgetTester tester, List<SpotOverview> rows) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    when(() => overview.search(any())).thenAnswer((_) async => rows);
    await tester.pumpApp(
      const SpotsMapScreen(),
      overrides: [
        spotOverviewRepositoryProvider.overrideWith((ref) async => overview),
        spotsRepositoryProvider.overrideWith((ref) async => spots),
        currentUserProvider.overrideWith(
          (ref) async => const AppUser(
            id: 'u1',
            email: 'feld@eiermann.test',
            role: UserRole.member,
            org: 'org00000default',
          ),
        ),
      ],
    );
    await tester.pumpAndSettle();
  }

  testWidgets('reads the view once for the whole screen', (tester) async {
    // Never one request per pin. A map that fires a request per building is
    // what makes this app feel broken on a phone in a stairwell — and the
    // counts and the urgency rank a pin needs are in the view already.
    await pumpMap(tester, [
      row(id: 's1', name: 'Bahnhofstraße 12'),
      row(id: 's2', name: 'Alter Speicher', lat: 53.99, lon: 9.99),
    ]);

    verify(() => overview.search('')).called(1);
    expect(find.byType(FlutterMap), findsOneWidget);
  });

  testWidgets('a Spot with NO pin is counted out loud, not dropped', (
    tester,
  ) async {
    // A map that quietly omits four buildings reads as a complete picture of
    // the group's work.
    await pumpMap(tester, [
      row(id: 's1', name: 'Mit Pin'),
      row(id: 's2', name: 'Ohne Pin', pinned: false),
      row(id: 's3', name: 'Auch ohne', pinned: false),
    ]);

    expect(find.text(de.spotsMapUnpinned(2)), findsOneWidget);
  });

  testWidgets('nothing about missing pins is said when they all have one', (
    tester,
  ) async {
    await pumpMap(tester, [row(id: 's1', name: 'Mit Pin')]);

    expect(find.text(de.spotsMapUnpinned(1)), findsNothing);
    expect(find.text(de.spotsMapUnpinned(0)), findsNothing);
  });

  testWidgets('a tapped pin says enough to decide whether to go', (
    tester,
  ) async {
    await pumpMap(tester, [
      row(
        id: 's1',
        name: 'Bahnhofstraße 12',
        urgency: 0,
        nextDueAt: DateTime.utc(2026, 8, 3),
        contactCount: 2,
      ),
    ]);

    await tester.tap(find.byIcon(Icons.location_on));
    await tester.pumpAndSettle();

    expect(find.text('Bahnhofstraße 12'), findsWidgets);
    // The rank in WORDS, not only as a colour: colour alone fails WCAG 1.4.1
    // and says nothing to a colour-blind reader.
    expect(find.textContaining(de.spotUrgencyOverdue), findsOneWidget);
    expect(find.text(de.spotContactCount(2)), findsOneWidget);
    expect(find.text(de.spotsMapOpenAction), findsOneWidget);
  });

  testWidgets('an UNCONFIRMED pin is flagged on the callout', (tester) async {
    // The map is exactly where this matters: a guessed pin on the wrong side of
    // a courtyard is what sends somebody to the wrong door.
    await pumpMap(tester, [
      row(id: 's1', name: 'Geraten', geoConfirmed: false),
    ]);
    await tester.tap(find.byIcon(Icons.location_on));
    await tester.pumpAndSettle();

    expect(find.text(de.spotPinUnconfirmed), findsOneWidget);
  });

  testWidgets('a confirmed pin says nothing about it', (tester) async {
    await pumpMap(tester, [row(id: 's1', name: 'Bestätigt')]);
    await tester.tap(find.byIcon(Icons.location_on));
    await tester.pumpAndSettle();

    expect(find.text(de.spotPinUnconfirmed), findsNothing);
  });

  group('clustering', () {
    testWidgets('Spots too close to tell apart become one counted pin', (
      tester,
    ) async {
      // Buildings in one block, about eleven metres apart: they overlap into a
      // blob where you can neither count them nor tap the one you want.
      await pumpMap(tester, [
        row(id: 's1', name: 'Haus A', lat: 53.1400, lon: 8.2100),
        row(id: 's2', name: 'Haus B', lat: 53.1401, lon: 8.2101),
        row(id: 's3', name: 'Haus C', lat: 53.1402, lon: 8.2102),
      ]);

      // One badge with the count, no individual pins.
      expect(find.text('3'), findsOneWidget);
      expect(find.byIcon(Icons.location_on), findsNothing);
    });

    testWidgets('a cluster opens the list rather than guessing a zoom', (
      tester,
    ) async {
      // Zooming is a guess at how far in the pins separate, and two Spots in
      // one courtyard never do.
      await pumpMap(tester, [
        row(id: 's1', name: 'Haus A', lat: 53.1400, lon: 8.2100),
        row(id: 's2', name: 'Haus B', lat: 53.1401, lon: 8.2101),
      ]);

      await tester.tap(find.text('2'));
      await tester.pumpAndSettle();

      expect(find.text('Haus A'), findsOneWidget);
      expect(find.text('Haus B'), findsOneWidget);
    });

    testWidgets('far-apart Spots stay separate pins', (tester) async {
      await pumpMap(tester, [
        row(id: 's1', name: 'Oldenburg', lat: 53.14, lon: 8.21),
        row(id: 's2', name: 'Berlin', lat: 52.52, lon: 13.40),
      ]);

      expect(find.byIcon(Icons.location_on), findsNWidgets(2));
    });
  });

  testWidgets('an empty org gets a map and a sentence, not a blank screen', (
    tester,
  ) async {
    await pumpMap(tester, const []);

    expect(find.byType(FlutterMap), findsOneWidget);
    expect(find.text(de.spotsEmptyTitle), findsOneWidget);
  });

  testWidgets('a failed read offers a retry', (tester) async {
    when(() => overview.search(any())).thenThrow(
      const RepositoryException('down', kind: RepositoryErrorKind.network),
    );
    await tester.pumpApp(
      const SpotsMapScreen(),
      overrides: [
        spotOverviewRepositoryProvider.overrideWith((ref) async => overview),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text(de.actionRetry), findsOneWidget);
  });

  testWidgets('a Spot added from the MAP appears on the map', (tester) async {
    // The map arrived as a second reader of the same rows, and every write site
    // was invalidating only the list — so a Spot created from this screen's own
    // button did not show up until the screen was left and re-entered.
    await pumpMap(tester, [row(id: 's1', name: 'Schon da')]);
    verify(() => overview.search('')).called(1);

    await tester.tap(find.text(de.spotsEmptyAction));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, de.spotFieldName),
      'Gerade angelegt',
    );
    await tester.tap(find.text(de.actionSave));
    await tester.pumpAndSettle();

    verify(() => spots.create(any())).called(1);
    // Re-read, so the new pin is drawn.
    verify(() => overview.search('')).called(1);
  });
}
