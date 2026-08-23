import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/spots/spot_pin_picker.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/ui/app_map.dart';
import 'package:eiermann/ui/device_location.dart';
import 'package:eiermann/ui/locate_me_button.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

import '../../support/harness.dart';

class _MockGeocoding extends Mock implements GeocodingRepository {}

/// The location seam. `Geolocator`'s API is static, so this is the only way the
/// auto-start and the refusal paths get tested at all.
///
/// A mock rather than a fake delegating one method to the other, deliberately:
/// the whole point of the second door is that it does NOT go through the one
/// that prompts, and a fake that forwarded would make `verifyNever` on
/// [DeviceLocation.current] pass for the wrong reason.
class _MockLocation extends Mock implements DeviceLocation {}

/// Hosts the picker behind a button, because it arrives as a pushed route and
/// returns its answer through `Navigator.pop`.
class _Host extends StatefulWidget {
  const _Host({this.initial});

  final GeoPoint? initial;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  PickedPin? picked;
  bool returned = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ElevatedButton(
            onPressed: () async {
              final result = await showSpotPinPicker(
                context,
                initial: widget.initial,
              );
              setState(() {
                picked = result;
                returned = true;
              });
            },
            child: const Text('open'),
          ),
          if (returned)
            Text(
              picked == null
                  ? 'nothing'
                  : '${picked!.point.lat},${picked!.point.lon}',
            ),
        ],
      ),
    ),
  );
}

void main() {
  late AppLocalizations de;
  late _MockGeocoding geocoding;
  late _MockLocation location;

  setUpAll(() async {
    de = await germanStrings();
  });

  setUp(() {
    geocoding = _MockGeocoding();
    location = _MockLocation();
    when(() => geocoding.reverse(any(), any())).thenAnswer((_) async => null);
    // No permission is the default across the suite, so every test that is not
    // ABOUT the auto-start behaves exactly as the picker did before it existed.
    when(() => location.currentIfPermitted()).thenAnswer((_) async => null);
  });

  Future<void> openPicker(WidgetTester tester, {GeoPoint? initial}) async {
    tester.useSurface(const Size(900, 1600));
    await tester.pumpApp(
      _Host(initial: initial),
      overrides: [
        geocodingRepositoryProvider.overrideWith((ref) async => geocoding),
        deviceLocationProvider.overrideWithValue(location),
      ],
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// Confirms whatever the crosshair is over and reads back what the host got.
  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(find.text(de.spotPinConfirmAction));
    await tester.pumpAndSettle();
  }

  testWidgets('a pin can be taken with NO address resolved at all', (
    tester,
  ) async {
    // The divergence from federfall's picker, and the reason for it: a
    // courtyard entrance behind a block may have no address, and an unreachable
    // geocoder must not stop somebody at the door from recording where it is.
    when(() => geocoding.reverse(any(), any())).thenThrow(
      const RepositoryException('down', kind: RepositoryErrorKind.network),
    );
    await openPicker(
      tester,
      initial: const GeoPoint(lat: 53.1435, lon: 8.2146),
    );

    expect(find.text(de.spotPinNoAddress), findsOneWidget);
    await tester.tap(find.text(de.spotPinConfirmAction));
    await tester.pumpAndSettle();

    // Came back with the pin it was given, not with nothing.
    expect(find.text('53.1435,8.2146'), findsOneWidget);
  });

  testWidgets('what is under the pin is named when the geocoder answers', (
    tester,
  ) async {
    when(() => geocoding.reverse(any(), any())).thenAnswer(
      (_) async => const GeoResult(
        lat: 53.1435,
        lon: 8.2146,
        displayName: 'Bahnhofstraße 12, 26122 Oldenburg',
      ),
    );
    await openPicker(
      tester,
      initial: const GeoPoint(lat: 53.1435, lon: 8.2146),
    );

    expect(find.text('Bahnhofstraße 12, 26122 Oldenburg'), findsOneWidget);
  });

  testWidgets('several candidates are offered rather than one being guessed', (
    tester,
  ) async {
    // "Bahnhofstraße 12" exists in a hundred towns. Taking the first silently
    // is how somebody drives to the wrong one.
    when(() => geocoding.forward(any())).thenAnswer(
      (_) async => const [
        GeoResult(lat: 53.1435, lon: 8.2146, displayName: 'Oldenburg'),
        GeoResult(lat: 52.52, lon: 13.4, displayName: 'Berlin'),
      ],
    );
    await openPicker(tester);
    await tester.enterText(find.byType(TextField), 'Bahnhofstraße 12');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('Oldenburg'), findsOneWidget);
    expect(find.text('Berlin'), findsOneWidget);

    await tester.tap(find.text('Berlin'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(de.spotPinConfirmAction));
    await tester.pumpAndSettle();

    expect(find.text('52.52,13.4'), findsOneWidget);
  });

  testWidgets('a search with no hits is not treated as an error', (
    tester,
  ) async {
    // Plenty of buildings a group cares about are not in a geocoder, and the
    // crosshair still works.
    when(() => geocoding.forward(any())).thenAnswer((_) async => const []);
    await openPicker(tester);
    await tester.enterText(find.byType(TextField), 'Hinterhof ohne Namen');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text(de.spotPinSearchNoMatch), findsOneWidget);
    expect(find.text(de.spotPinConfirmAction), findsOneWidget);
  });

  testWidgets('a failing SEARCH says why, and leaves the map usable', (
    tester,
  ) async {
    when(() => geocoding.forward(any())).thenThrow(
      const RepositoryException('down', kind: RepositoryErrorKind.network),
    );
    await openPicker(tester);
    await tester.enterText(find.byType(TextField), 'Oldenburg');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text(de.errorOffline), findsOneWidget);
    // Still able to confirm whatever the map is showing.
    expect(find.text(de.spotPinConfirmAction), findsOneWidget);
  });

  group('the map opens where the reader is standing', () {
    // Whoever records a NEW Spot is, in practice, on the pavement in front of
    // it. Opening over the middle of Germany at zoom 5 means zooming or
    // searching before anything is visible at all.

    testWidgets('a new Spot starts on the device position, address and all', (
      tester,
    ) async {
      when(() => location.currentIfPermitted()).thenAnswer(
        (_) async => (lat: 53.1435, lon: 8.2146),
      );
      when(() => geocoding.reverse(any(), any())).thenAnswer(
        (_) async => const GeoResult(
          lat: 53.1435,
          lon: 8.2146,
          displayName: 'Bahnhofstraße 12, 26122 Oldenburg',
        ),
      );

      await openPicker(tester);

      // The strip is resolved, not blank: the fix moves the CAMERA, and
      // without an explicit resolve the address line would sit on "keine
      // Adresse" under a map already showing the right building.
      expect(find.text('Bahnhofstraße 12, 26122 Oldenburg'), findsOneWidget);
      verify(() => geocoding.reverse(53.1435, 8.2146)).called(1);

      // And the state followed the camera — confirming returns the fix, not
      // the fallback centre it was built with.
      await confirm(tester);
      expect(find.text('53.1435,8.2146'), findsOneWidget);
    });

    testWidgets('without the permission it does NOT ask, and says nothing', (
      tester,
    ) async {
      // The one that matters. Opening a screen is not asking, so a system
      // permission dialog on top of it is a question nobody posed — and a
      // refusal nobody asked for is not worth a snackbar either.
      await openPicker(tester);

      verify(() => location.currentIfPermitted()).called(1);
      verifyNever(() => location.current());
      expect(find.byType(SnackBar), findsNothing);

      // Still on the fallback, exactly as before the auto-start existed.
      await confirm(tester);
      expect(
        find.text(
          '${kMapFallbackCentre.latitude},'
          '${kMapFallbackCentre.longitude}',
        ),
        findsOneWidget,
      );
    });

    testWidgets('correcting an existing pin is never touched by the device', (
      tester,
    ) async {
      // The pin being corrected IS the statement. Where the phone happens to
      // be standing is not an improvement on it — somebody may well be fixing
      // a pin for a building on the other side of town.
      await openPicker(
        tester,
        initial: const GeoPoint(lat: 53.1435, lon: 8.2146),
      );

      verifyNever(() => location.currentIfPermitted());
      verifyNever(() => location.current());

      await confirm(tester);
      expect(find.text('53.1435,8.2146'), findsOneWidget);
    });
  });

  group('the "mein Standort" button', () {
    testWidgets('does not sit on top of either control it shares a map with', (
      tester,
    ) async {
      // The bug this replaces: as the Scaffold's `floatingActionButton` at
      // `endTop` the button landed at 336..384 x 80..128 on a 400x800 phone —
      // inside the full-width search card at 8..392 x 64..136, right over the
      // search arrow. The other obvious slot, the default bottom-right corner,
      // covers "Diese Stelle übernehmen" instead. A phone screen is small
      // enough that a third control has to be PLACED, not dropped in a corner
      // and hoped for.
      //
      // Rects rather than `findsOneWidget`, because the button was found the
      // whole time it was unusable: an overlapping FAB is present, hit-tested
      // and on top.
      tester.useSurface(const Size(400, 800));
      await tester.pumpApp(
        const SpotPinPicker(),
        overrides: [
          geocodingRepositoryProvider.overrideWith((ref) async => geocoding),
          deviceLocationProvider.overrideWithValue(location),
        ],
      );
      await tester.pumpAndSettle();

      final button = tester.getRect(find.byType(LocateMeButton));
      // The search card is the topmost Card on this screen.
      final search = tester.getRect(find.byType(Card).first);
      final confirm = tester.getRect(find.text(de.spotPinConfirmAction));

      expect(button.overlaps(search), isFalse, reason: 'over the search field');
      expect(button.overlaps(confirm), isFalse, reason: 'over the confirm');
    });

    testWidgets('asks, and brings the camera back once it has an answer', (
      tester,
    ) async {
      // The button is what asks: a press IS somebody asking. It exists so the
      // camera can be recalled after a pan, which the auto-start alone cannot
      // do.
      when(() => location.current()).thenAnswer(
        (_) async => (lat: 52.52, lon: 13.4),
      );
      await openPicker(tester);

      await tester.tap(find.byIcon(Icons.my_location));
      await tester.pumpAndSettle();

      await confirm(tester);
      expect(find.text('52.52,13.4'), findsOneWidget);
    });

    for (final (reason, message) in [
      (LocationRefusal.serviceOff, 'spotsMapLocationServiceOff'),
      (LocationRefusal.denied, 'spotsMapLocationDenied'),
      (LocationRefusal.deniedForever, 'spotsMapLocationBlocked'),
      (LocationRefusal.unavailable, 'spotsMapLocationUnavailable'),
    ]) {
      testWidgets('$message: the refusal says which one it was', (
        tester,
      ) async {
        // Four cases and not one "Standort nicht verfügbar", because the next
        // move differs in each: switch the service on, grant again, or open the
        // system settings. One sentence for all four sends people looking in
        // the wrong place.
        when(() => location.current()).thenThrow(LocationUnavailable(reason));
        await openPicker(tester);

        await tester.tap(find.byIcon(Icons.my_location));
        await tester.pumpAndSettle();

        expect(find.text(refusalText(de, reason)), findsOneWidget);
        // The map stays usable: a refused permission is not a dead end.
        expect(find.text(de.spotPinConfirmAction), findsOneWidget);
      });
    }
  });

  testWidgets('a tap moves the answer, not just the camera', (tester) async {
    // A programmatic `MapController.move` emits no `MapEventMoveEnd` — only a
    // drag does — so a tap that moved the camera and left the state alone
    // returned the place the picker used to be looking at. Confirming after a
    // tap well off centre must not hand back the point it opened on.
    await openPicker(
      tester,
      initial: const GeoPoint(lat: 53.1435, lon: 8.2146),
    );

    final map = tester.getRect(find.byType(FlutterMap));
    await tester.tapAt(map.center + const Offset(0, -200));
    // The explicit advance, not just `pumpAndSettle`: flutter_map holds a tap
    // back to see whether a DOUBLE tap follows, and that hold is a `Timer`.
    // A pending timer schedules no frames, so settling alone leaves the tap
    // unfired and the assertion would describe the state before it.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    await confirm(tester);
    expect(find.text('53.1435,8.2146'), findsNothing);
  });
}

/// The German sentence for a refusal, so the table above names the case rather
/// than repeating the switch the widget uses.
String refusalText(AppLocalizations l10n, LocationRefusal reason) =>
    switch (reason) {
      LocationRefusal.serviceOff => l10n.spotsMapLocationServiceOff,
      LocationRefusal.denied => l10n.spotsMapLocationDenied,
      LocationRefusal.deniedForever => l10n.spotsMapLocationBlocked,
      LocationRefusal.unavailable => l10n.spotsMapLocationUnavailable,
    };
