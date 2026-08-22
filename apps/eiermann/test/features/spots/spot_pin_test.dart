import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/spots/spot_sheet.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

import '../../support/harness.dart';

class _MockSpots extends Mock implements SpotsRepository {}

class _MockGeocoding extends Mock implements GeocodingRepository {}

/// Opens the sheet the way the app opens it — through a pushed route, so the
/// discard guard and the picker's own push both have a Navigator.
class _Host extends StatelessWidget {
  const _Host({this.spot});

  final Spot? spot;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ElevatedButton(
        onPressed: () => showSpotSheet(context, spot: spot),
        child: const Text('open'),
      ),
    ),
  );
}

void main() {
  late AppLocalizations de;
  late _MockSpots spots;
  late _MockGeocoding geocoding;

  setUpAll(() async {
    de = await germanStrings();
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() {
    spots = _MockSpots();
    geocoding = _MockGeocoding();
    when(() => spots.create(any())).thenAnswer(
      (_) async => const Spot(id: 's-new', name: 'Bahnhofstraße 12'),
    );
    when(() => spots.update(any(), any())).thenAnswer(
      (_) async => const Spot(id: 's1', name: 'Bahnhofstraße 12'),
    );
  });

  Future<void> openSheet(WidgetTester tester, {Spot? spot}) async {
    tester.useSurface(const Size(900, 2000));
    await tester.pumpApp(
      _Host(spot: spot),
      overrides: [
        spotsRepositoryProvider.overrideWith((ref) async => spots),
        geocodingRepositoryProvider.overrideWith((ref) async => geocoding),
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
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> typeAddress(WidgetTester tester) async {
    await tester.enterText(
      find.widgetWithText(TextFormField, de.spotFieldName),
      'Bahnhofstraße 12',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, de.spotFieldStreet),
      'Bahnhofstraße 12',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, de.spotFieldCity),
      'Oldenburg',
    );
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> createdBody() =>
      verify(() => spots.create(captureAny())).captured.single
          as Map<String, dynamic>;

  group('the pin field', () {
    testWidgets('says what a MISSING pin costs, rather than sitting blank', (
      tester,
    ) async {
      // A Spot with no coordinates is findable by name and appears on no map —
      // and the map is the entry point for every round.
      await openSheet(tester);

      expect(find.text(de.spotPinNone), findsOneWidget);
    });

    testWidgets('tells a derived pin apart from a confirmed one', (
      tester,
    ) async {
      // Not degrees of the same thing: one is a guess at a postal address, the
      // other is a person who stood in front of the building.
      await openSheet(
        tester,
        spot: const Spot(
          id: 's1',
          name: 'Bahnhofstraße 12',
          phase: SpotPhase.active,
          geo: GeoPoint(lat: 53.1435, lon: 8.2146),
        ),
      );
      expect(find.text(de.spotPinFromAddress), findsOneWidget);
      expect(find.text(de.spotPinConfirmed), findsNothing);
    });

    testWidgets('a confirmed pin says so', (tester) async {
      await openSheet(
        tester,
        spot: const Spot(
          id: 's1',
          name: 'Bahnhofstraße 12',
          phase: SpotPhase.active,
          geo: GeoPoint(lat: 53.1435, lon: 8.2146),
          geoConfirmed: true,
        ),
      );
      expect(find.text(de.spotPinConfirmed), findsOneWidget);
    });
  });

  group('the location comes from the map, not the address', () {
    testWidgets('the pin card leads — it is above the address fields', (
      tester,
    ) async {
      // The whole point of the rework. A pigeon Spot is frequently not at an
      // address: a light well between two blocks, the back of a courtyard
      // reached through a different building's gate. A form that puts the
      // address first says the address is the location.
      await openSheet(tester);

      final pinY = tester.getTopLeft(find.text(de.spotFieldPin)).dy;
      final streetY = tester
          .getTopLeft(find.widgetWithText(TextFormField, de.spotFieldStreet))
          .dy;
      expect(pinY, lessThan(streetY));
      // And the address says what it is for.
      expect(find.text(de.spotAddressAsLabel), findsOneWidget);
    });

    testWidgets('there is exactly ONE route to a pin, and it is the map', (
      tester,
    ) async {
      // The second route — "look it up from the address" — is gone. It quietly
      // made the address the source of the location, which for a Spot between
      // buildings is the wrong answer dressed as a precise one.
      await openSheet(tester);

      expect(find.text(de.spotPinSetAction), findsOneWidget);
      expect(find.text(de.spotPinFindAction), findsNothing);
      verifyNever(() => geocoding.forward(any()));
    });

    testWidgets('the map opens seeded with whatever address was typed', (
      tester,
    ) async {
      // Nothing got slower: the picker still searches addresses, so a
      // well-formed one is still one tap away from a pin.
      when(() => geocoding.forward(any())).thenAnswer((_) async => const []);
      when(() => geocoding.reverse(any(), any())).thenAnswer((_) async => null);
      await openSheet(tester);
      await typeAddress(tester);
      await tester.tap(find.text(de.spotPinSetAction));
      await tester.pumpAndSettle();

      expect(find.text(de.spotPinPickerTitle), findsOneWidget);
      expect(find.text('Bahnhofstraße 12, Oldenburg'), findsOneWidget);
    });

    testWidgets('a placed pin FILLS the empty address fields', (tester) async {
      // The ordinary case: a building with a front door on a street. Retyping
      // an address the app already knows is pointless work.
      const found = GeoResult(
        lat: 53.1435,
        lon: 8.2146,
        displayName: 'Bahnhofstraße 12, 26122 Oldenburg',
        city: 'Oldenburg',
      );
      when(
        () => geocoding.reverse(any(), any()),
      ).thenAnswer((_) async => found);
      when(() => geocoding.forward(any())).thenAnswer((_) async => [found]);
      await openSheet(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, de.spotFieldName),
        'Bahnhofstraße 12',
      );
      await tester.tap(find.text(de.spotPinSetAction));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Bahnhofstraße 12');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      await tester.tap(find.text(de.spotPinConfirmAction));
      await tester.pumpAndSettle();
      await tester.tap(find.text(de.actionSave));
      await tester.pumpAndSettle();

      final body = createdBody();
      expect(body['geo'], {'lon': 8.2146, 'lat': 53.1435});
      // Somebody looked at the map and put it there.
      expect(body['geo_confirmed'], true);
      // Read back out of the proxy's own composed displayName.
      expect(body['street'], 'Bahnhofstraße 12');
      expect(body['postal_code'], '26122');
      expect(body['city'], 'Oldenburg');
    });

    testWidgets('...and NEVER overwrites what a person already typed', (
      tester,
    ) async {
      // The half that keeps this form honest for the case its field order
      // exists to handle. A courtyard has no address of its own, so what
      // somebody wrote about it beats the neighbour's official one — and a form
      // that replaced it would be quietly wrong in exactly that situation.
      const neighbour = GeoResult(
        lat: 53.1435,
        lon: 8.2146,
        displayName: 'Nachbarhaus 3, 26122 Oldenburg',
        city: 'Oldenburg',
      );
      when(
        () => geocoding.reverse(any(), any()),
      ).thenAnswer((_) async => neighbour);
      when(
        () => geocoding.forward(any()),
      ).thenAnswer((_) async => [neighbour]);
      await openSheet(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, de.spotFieldName),
        'Lichtschacht hinterm Block',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, de.spotFieldStreet),
        'Ecke Bahnhofstraße / Am Wall',
      );
      await tester.tap(find.text(de.spotPinSetAction));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Nachbarhaus 3');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      await tester.tap(find.text(de.spotPinConfirmAction));
      await tester.pumpAndSettle();

      // The map's answer stays visible as the provenance — and, here, as the
      // warning that it belongs to the building next door.
      expect(
        find.text(de.spotPinAccordingToMap('Nachbarhaus 3, 26122 Oldenburg')),
        findsOneWidget,
      );

      await tester.tap(find.text(de.actionSave));
      await tester.pumpAndSettle();

      final body = createdBody();
      expect(body['street'], 'Ecke Bahnhofstraße / Am Wall');
      // The empty ones still got filled — the rule is per field, not per form.
      expect(body['postal_code'], '26122');
      expect(body['city'], 'Oldenburg');
    });

    testWidgets('a pin the geocoder cannot name invents no address', (
      tester,
    ) async {
      // A bridge underside. The proxy falls back to the geocoder's own long
      // form, whose first segment is a house number — "3" in a street field
      // would look exactly like something a person typed.
      const unnameable = GeoResult(
        lat: 53.1435,
        lon: 8.2146,
        displayName:
            '3, Nachbarhaus, Innenstadt, Oldenburg, 26122, '
            'Deutschland',
        city: 'Oldenburg',
      );
      when(
        () => geocoding.reverse(any(), any()),
      ).thenAnswer((_) async => unnameable);
      when(
        () => geocoding.forward(any()),
      ).thenAnswer((_) async => [unnameable]);
      await openSheet(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, de.spotFieldName),
        'Unter der Brücke',
      );
      await tester.tap(find.text(de.spotPinSetAction));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Brücke');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      await tester.tap(find.text(de.spotPinConfirmAction));
      await tester.pumpAndSettle();
      await tester.tap(find.text(de.actionSave));
      await tester.pumpAndSettle();

      final body = createdBody();
      expect(body['street'], '');
      expect(body['postal_code'], '');
      // The city IS reliable — the proxy returns it as its own field.
      expect(body['city'], 'Oldenburg');
    });
  });

  group('the phase', () {
    testWidgets('offers only the two phases a Spot can START in', (
      tester,
    ) async {
      // Pausing and closing need a reason the server insists on, and this form
      // has nowhere to ask for it — so offering them was offering two
      // guaranteed refusals out of four.
      await openSheet(tester);
      await tester.tap(find.text(de.spotPhaseLabel));
      await tester.pumpAndSettle();

      expect(find.text(de.spotPhaseProspect), findsWidgets);
      expect(find.text(de.spotPhaseActive), findsWidgets);
      expect(find.text(de.spotPhasePaused), findsNothing);
      expect(find.text(de.spotPhaseClosed), findsNothing);
    });

    testWidgets('is not offered AT ALL on an edit', (tester) async {
      // The dossier's phase chip owns every change, because that is where the
      // reason gets collected.
      await openSheet(
        tester,
        spot: const Spot(
          id: 's1',
          name: 'Bahnhofstraße 12',
          phase: SpotPhase.active,
        ),
      );

      expect(find.text(de.spotPhaseLabel), findsNothing);
    });

    testWidgets('an edit keeps the phase it found, untouched', (tester) async {
      await openSheet(
        tester,
        spot: const Spot(
          id: 's1',
          name: 'Bahnhofstraße 12',
          phase: SpotPhase.paused,
          pauseReason: 'Gerüst',
        ),
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, de.spotFieldNote),
        'Notiz',
      );
      await tester.tap(find.text(de.actionSave));
      await tester.pumpAndSettle();

      final body =
          verify(() => spots.update('s1', captureAny())).captured.single
              as Map<String, dynamic>;
      // Sent as it was, not defaulted: `body` writes every field it is given
      // and the column is required.
      expect(body['phase'], SpotPhase.paused.wire);
    });

    testWidgets('a phase this build cannot name is OMITTED, not rewritten', (
      tester,
    ) async {
      // A server that gained a fifth phase. Sending a default would quietly
      // rewrite it to `prospect`; PocketBase reads an absent key as "leave it".
      await openSheet(
        tester,
        spot: const Spot(id: 's1', name: 'Unbekannte Phase'),
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, de.spotFieldNote),
        'Notiz',
      );
      await tester.tap(find.text(de.actionSave));
      await tester.pumpAndSettle();

      final body =
          verify(() => spots.update('s1', captureAny())).captured.single
              as Map<String, dynamic>;
      expect(body.containsKey('phase'), isFalse);
    });
  });

  group('saving without a pin', () {
    testWidgets('omits geo entirely rather than writing 0, 0', (tester) async {
      // PocketBase has no null for a geoPoint, so {0, 0} IS "no pin" on the
      // wire — but sending it would overwrite a pin another screen placed, and
      // reading it back gives a plausible marker in the Gulf of Guinea.
      await openSheet(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, de.spotFieldName),
        'Ohne Pin',
      );
      await tester.tap(find.text(de.actionSave));
      await tester.pumpAndSettle();

      final body = createdBody();
      expect(body.containsKey('geo'), isFalse);
      expect(body['name'], 'Ohne Pin');
    });

    testWidgets('an existing pin survives an edit that never touches it', (
      tester,
    ) async {
      await openSheet(
        tester,
        spot: const Spot(
          id: 's1',
          name: 'Bahnhofstraße 12',
          phase: SpotPhase.active,
          geo: GeoPoint(lat: 53.1435, lon: 8.2146),
          geoConfirmed: true,
        ),
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, de.spotFieldNote),
        'Nur eine Notiz',
      );
      await tester.tap(find.text(de.actionSave));
      await tester.pumpAndSettle();

      final body =
          verify(() => spots.update('s1', captureAny())).captured.single
              as Map<String, dynamic>;
      expect(body['geo'], {'lon': 8.2146, 'lat': 53.1435});
      // And the flag rides along unchanged: this edit did not re-place the pin,
      // so it did not un-confirm it either.
      expect(body['geo_confirmed'], true);
    });
  });
}
