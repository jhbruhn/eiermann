import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/spots/spots_map_screen.dart';
import 'package:eiermann/features/spots/spots_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/ui/device_location.dart';
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

/// The location seam. `Geolocator`'s API is static, so this is the only way the
/// refusal paths get tested at all — the alternative is denying a real
/// permission on a real device.
class _MockLocation extends Mock implements DeviceLocation {}

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
  late _MockLocation location;

  setUpAll(() async {
    de = await germanStrings();
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() {
    overview = _MockOverview();
    spots = _MockSpots();
    location = _MockLocation();
    when(() => spots.create(any())).thenAnswer(
      (_) async => const Spot(id: 's-new', name: 'Neu'),
    );
  });

  Future<void> pumpMap(
    WidgetTester tester,
    List<SpotOverview> rows, {
    Map<String, List<SpotOverview>> matching = const {},
  }) async {
    tester.useSurface(const Size(900, 1600));
    when(() => overview.search(any())).thenAnswer(
      (call) async =>
          matching[call.positionalArguments.first as String] ?? rows,
    );
    await tester.pumpApp(
      const SpotsMapScreen(),
      overrides: [
        spotOverviewRepositoryProvider.overrideWith((ref) async => overview),
        spotsRepositoryProvider.overrideWith((ref) async => spots),
        deviceLocationProvider.overrideWithValue(location),
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

  /// Types [text] into the search field and lets the debounce elapse.
  ///
  /// The explicit clock advance is the whole point, and it cost an hour:
  /// `pumpAndSettle` pumps only WHILE frames are scheduled, and a pending
  /// `Timer` schedules none — so typing and settling leaves the debounce
  /// unfired and every assertion about the search describes the state before
  /// it. The first version of these tests "passed" that way in one case and
  /// failed in another, depending on whether a chip animation happened to keep
  /// frames coming.
  Future<void> search(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump(kSpotSearchDebounce + const Duration(milliseconds: 50));
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
    // and says nothing to a colour-blind reader. Scoped to the callout,
    // because the filter chip above the map names the same rank — and a bare
    // `findsOneWidget` would break the moment a second place says it right.
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.textContaining(de.spotUrgencyOverdue),
      ),
      findsOneWidget,
    );
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

  group('the rank filter', () {
    testWidgets('a chip names its rank AND how many sit in it', (tester) async {
      // The number is on the chip so the filter says how much work it is about
      // to show before it is tapped.
      await pumpMap(tester, [
        row(id: 's1', name: 'Spät', urgency: 0),
        row(id: 's2', name: 'Auch spät', urgency: 0, lat: 53.9, lon: 8.9),
        row(id: 's3', name: 'Im Rhythmus', lat: 54.2, lon: 9.2),
      ]);

      expect(
        find.widgetWithText(FilterChip, '${de.spotUrgencyOverdue} · 2'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(FilterChip, '${de.spotUrgencyInRhythm} · 1'),
        findsOneWidget,
      );
    });

    testWidgets('selecting one draws only its pins — with NO new query', (
      tester,
    ) async {
      // The rank is the value the view already computed and the pin is already
      // coloured by. A query for it could only disagree with the colour on
      // screen, and it would cost a round trip to do so.
      await pumpMap(tester, [
        row(id: 's1', name: 'Spät', urgency: 0),
        row(id: 's2', name: 'Im Rhythmus', lat: 54.2, lon: 9.2),
      ]);
      expect(find.byIcon(Icons.location_on), findsNWidgets(2));

      await tester.tap(
        find.widgetWithText(FilterChip, '${de.spotUrgencyOverdue} · 1'),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.location_on), findsOneWidget);
      verify(() => overview.search('')).called(1);
    });

    testWidgets('a rank whose rows have NO pin says which of the two it is', (
      tester,
    ) async {
      // Nothing is drawn, and the reason is not the filter: the building that
      // matches has no pin. Two different sentences for two different fixes.
      await pumpMap(tester, [
        row(id: 's1', name: 'Spät', urgency: 0),
        row(id: 's2', name: 'Ohne Pin', pinned: false),
      ]);

      await tester.tap(
        find.widgetWithText(FilterChip, '${de.spotUrgencyInRhythm} · 1'),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.location_on), findsNothing);
      expect(find.text(de.spotsMapUnpinned(1)), findsOneWidget);
    });

    testWidgets('a chip that empties a SEARCH result stays on screen', (
      tester,
    ) async {
      // The trap this closes: the chip is drawn per rank that HAS rows, so a
      // search matching nothing at the selected rank would remove the only
      // control that could switch it off — a map filtered by an invisible chip.
      await pumpMap(
        tester,
        [
          row(id: 's1', name: 'Spät', urgency: 0),
          row(id: 's2', name: 'Im Rhythmus', lat: 54.2, lon: 9.2),
        ],
        matching: {
          'rhyth': [
            row(id: 's2', name: 'Im Rhythmus', lat: 54.2, lon: 9.2),
          ],
        },
      );

      await tester.tap(
        find.widgetWithText(FilterChip, '${de.spotUrgencyOverdue} · 1'),
      );
      await tester.pumpAndSettle();
      await search(tester, 'rhyth');

      expect(find.text(de.spotsFilterEmpty), findsOneWidget);
      final chip = find.widgetWithText(
        FilterChip,
        '${de.spotUrgencyOverdue} · 0',
      );
      expect(chip, findsOneWidget, reason: 'the way back has to stay visible');

      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.location_on), findsOneWidget);
    });

    testWidgets('tapping the selected chip clears it', (tester) async {
      // One gesture for both directions; no separate "all" chip to find.
      await pumpMap(tester, [
        row(id: 's1', name: 'Spät', urgency: 0),
        row(id: 's2', name: 'Im Rhythmus', lat: 54.2, lon: 9.2),
      ]);
      final chip = find.widgetWithText(
        FilterChip,
        '${de.spotUrgencyOverdue} · 1',
      );

      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.location_on), findsOneWidget);

      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.location_on), findsNWidgets(2));
    });

    testWidgets('all seven ranks fit on a phone', (tester) async {
      // The controls are a card OVER the map, and seven chips is the worst
      // case. Wrapped onto three lines they would cover the thing they filter;
      // this is the test that fails if the row ever stops scrolling.
      tester.useSurface(const Size(360, 800));
      await pumpMap(tester, [
        for (final level in SpotUrgency.values)
          row(
            id: 's${level.rank}',
            name: 'Haus ${level.rank}',
            urgency: level.rank,
            lat: 53.5 + level.rank / 10,
          ),
      ]);

      expect(find.byType(FilterChip), findsNWidgets(SpotUrgency.values.length));
      // A layout overflow is an exception, and an exception fails this test —
      // so the assertion above is only half of what this covers.
      expect(tester.takeException(), isNull);
    });
  });

  group('the search', () {
    testWidgets('a burst of keystrokes is ONE query', (tester) async {
      // A keystroke is a request otherwise. The map holds every row, but the
      // matching is the server's — the columns a term is tried against live in
      // the view's filter, and a Dart copy of that would drift from the list's.
      await pumpMap(
        tester,
        [row(id: 's1', name: 'Bahnhofstraße 12')],
        matching: {
          'bahn': [row(id: 's1', name: 'Bahnhofstraße 12')],
        },
      );

      // Typed inside the debounce window, so only the last term is asked for.
      await tester.enterText(find.byType(TextField), 'b');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField), 'ba');
      await tester.pump(const Duration(milliseconds: 100));
      await search(tester, 'bahn');

      verify(() => overview.search('bahn')).called(1);
      verifyNever(() => overview.search('b'));
      verifyNever(() => overview.search('ba'));
    });

    testWidgets('nothing matching says so, and not "no buildings"', (
      tester,
    ) async {
      await pumpMap(
        tester,
        [row(id: 's1', name: 'Bahnhofstraße 12')],
        matching: {'kanal': []},
      );

      await search(tester, 'kanal');

      expect(find.text(de.spotsNoMatches), findsOneWidget);
      expect(find.byIcon(Icons.location_on), findsNothing);
      // And NOT the empty-org card. An org full of buildings called empty
      // because a search missed is the one thing this screen must not say.
      expect(find.text(de.spotsEmptyTitle), findsNothing);
    });

    testWidgets('the field survives the request it fired', (tester) async {
      // The controls sit above the map's async state. Rebuilt inside it, the
      // field would lose focus on every request and the reader could type one
      // term at a time.
      await pumpMap(
        tester,
        [row(id: 's1', name: 'Bahnhofstraße 12')],
        matching: {
          'bahn': [row(id: 's1', name: 'Bahnhofstraße 12')],
        },
      );

      await search(tester, 'bahn');

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'bahn',
      );
      verify(() => overview.search('bahn')).called(1);
    });
  });

  group('in meiner Nähe', () {
    testWidgets('puts the camera where the reader is, and marks it', (
      tester,
    ) async {
      when(
        () => location.current(),
      ).thenAnswer((_) async => (lat: 53.14, lon: 8.21));
      await pumpMap(tester, [
        row(id: 's1', name: 'Bahnhofstraße 12', lat: 53.141, lon: 8.211),
      ]);

      await tester.tap(find.byIcon(Icons.my_location));
      await tester.pumpAndSettle();

      final camera = tester
          .widget<FlutterMap>(find.byType(FlutterMap))
          .mapController!
          .camera;
      expect(camera.center.latitude, closeTo(53.14, 0.0001));
      expect(camera.center.longitude, closeTo(8.21, 0.0001));
      // The dot is not a pin: it marks a point, not a building, so nobody reads
      // their own position as a Spot that was never recorded.
      expect(find.bySemanticsLabel(de.spotsMapYouAreHere), findsOneWidget);
      // And the Spot is still drawn — "near me" moves the camera, it does not
      // filter to a radius. The one 300 m away is the reason to walk. It sits
      // next to the fix on purpose: flutter_map culls a marker outside the
      // viewport, so a distant Spot would read as filtered away when it is
      // only off-screen.
      expect(find.byIcon(Icons.location_on), findsOneWidget);
    });

    // One test per case rather than a loop inside one: each needs a fresh app,
    // because a SnackBar from the previous case is still on screen while the
    // next one is queued behind it — which reads as the wrong sentence missing.
    //
    // The loop runs at COLLECTION time, before `setUpAll` — so it cannot read
    // `de`, and the sentence is looked up inside the test body instead.
    for (final reason in LocationRefusal.values) {
      testWidgets('${reason.name} gets its OWN sentence', (tester) async {
        final message = switch (reason) {
          LocationRefusal.serviceOff => de.spotsMapLocationServiceOff,
          LocationRefusal.denied => de.spotsMapLocationDenied,
          LocationRefusal.deniedForever => de.spotsMapLocationBlocked,
          LocationRefusal.unavailable => de.spotsMapLocationUnavailable,
        };
        // The next move differs per case: a service is switched on, a
        // permission is granted again, a blocked one can only change in the
        // system settings. "Location unavailable" for all three sends somebody
        // looking in the wrong place.
        when(() => location.current()).thenThrow(LocationUnavailable(reason));
        await pumpMap(tester, [row(id: 's1', name: 'Bahnhofstraße 12')]);

        await tester.tap(find.byIcon(Icons.my_location));
        await tester.pumpAndSettle();

        expect(find.text(message), findsOneWidget);
        // No dot: nothing was located, and a stale one would claim otherwise.
        expect(find.bySemanticsLabel(de.spotsMapYouAreHere), findsNothing);
      });
    }
  });
}
