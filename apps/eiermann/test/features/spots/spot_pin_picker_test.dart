import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/spots/spot_pin_picker.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

import '../../support/harness.dart';

class _MockGeocoding extends Mock implements GeocodingRepository {}

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

  setUpAll(() async {
    de = await germanStrings();
  });

  setUp(() {
    geocoding = _MockGeocoding();
    when(() => geocoding.reverse(any(), any())).thenAnswer((_) async => null);
  });

  Future<void> openPicker(WidgetTester tester, {GeoPoint? initial}) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpApp(
      _Host(initial: initial),
      overrides: [
        geocodingRepositoryProvider.overrideWith((ref) async => geocoding),
      ],
    );
    await tester.tap(find.text('open'));
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
}
