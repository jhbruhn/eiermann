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
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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

  group('looking the pin up from the address', () {
    testWidgets('sends the typed address as one query', (tester) async {
      when(() => geocoding.forward(any())).thenAnswer((_) async => const []);
      await openSheet(tester);
      await typeAddress(tester);
      await tester.tap(find.text(de.spotPinFindAction));
      await tester.pumpAndSettle();

      verify(() => geocoding.forward('Bahnhofstraße 12, Oldenburg')).called(1);
    });

    testWidgets('a single hit becomes the pin, UNCONFIRMED, and says which', (
      tester,
    ) async {
      // Unconfirmed is the whole point: the geocoder put the pin on the postal
      // address, and which door somebody actually goes to is a different
      // question that only a person can answer.
      when(() => geocoding.forward(any())).thenAnswer(
        (_) async => const [
          GeoResult(
            lat: 53.1435,
            lon: 8.2146,
            displayName: 'Bahnhofstraße 12, 26122 Oldenburg',
          ),
        ],
      );
      await openSheet(tester);
      await typeAddress(tester);
      await tester.tap(find.text(de.spotPinFindAction));
      await tester.pumpAndSettle();

      expect(find.text(de.spotPinFromAddress), findsOneWidget);
      // Names what it took — a plausible street in the wrong town is the
      // failure mode, and it is invisible unless the app says which it chose.
      expect(
        find.text(
          de.spotPinFoundOne('Bahnhofstraße 12, 26122 Oldenburg'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text(de.actionSave));
      await tester.pumpAndSettle();

      final body = createdBody();
      expect(body['geo'], {'lon': 8.2146, 'lat': 53.1435});
      expect(body['geo_confirmed'], false);
    });

    testWidgets('an unreachable geocoder is not a dead end', (tester) async {
      // The map still works with the geocoder down, so this reports and stays
      // out of the way rather than blocking the save.
      when(() => geocoding.forward(any())).thenThrow(
        const RepositoryException('down', kind: RepositoryErrorKind.network),
      );
      await openSheet(tester);
      await typeAddress(tester);
      await tester.tap(find.text(de.spotPinFindAction));
      await tester.pumpAndSettle();

      expect(find.text(de.spotPinLookupFailed), findsOneWidget);
      expect(find.text(de.spotPinNone), findsOneWidget);

      await tester.tap(find.text(de.actionSave));
      await tester.pumpAndSettle();

      // Saved without a pin rather than refused. The address is the identity.
      final body = createdBody();
      expect(body.containsKey('geo'), isFalse);
      expect(body.containsKey('geo_confirmed'), isFalse);
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
