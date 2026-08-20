import 'package:eiermann/features/server_setup/setup_screen.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zugvogel_pb_client/zugvogel_pb_client.dart';

import '../../support/harness.dart';

/// A probe whose upstream answer the test dictates.
ServerProbe probeAnswering(Future<Object?> Function(String) prober) =>
    ServerProbe(
      config: const PbClientConfig(
        service: 'eiermann',
        fallbackServerName: 'Eiermann',
        mapFallback: MapConfig(
          mode: MapMode.raster,
          url: 'https://t.example/{z}/{x}/{y}.png',
          attribution: '© Example',
        ),
      ),
      prober: prober,
    );

void main() {
  late AppLocalizations de;

  setUpAll(() async => de = await germanStrings());

  setUp(() {
    // The success path persists the URL, and that goes through
    // SharedPreferences — which has no platform channel in a widget test.
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpWith(
    WidgetTester tester,
    Future<Object?> Function(String) prober,
  ) => tester.pumpApp(
    const SetupScreen(),
    overrides: [
      serverProbeProvider.overrideWithValue(probeAnswering(prober)),
    ],
  );

  testWidgets('asks for an address', (tester) async {
    await pumpWith(tester, (_) async => null);
    expect(find.text(de.setupTitle), findsOneWidget);
    expect(find.text(de.setupExplanation), findsOneWidget);
    expect(find.text(de.setupConnectAction), findsOneWidget);
  });

  testWidgets('an empty address is refused before any request', (tester) async {
    var probed = false;
    await pumpWith(tester, (_) async {
      probed = true;
      return null;
    });
    await tester.tap(find.text(de.setupConnectAction));
    await tester.pumpAndSettle();

    expect(find.text(de.fieldRequired), findsOneWidget);
    expect(probed, isFalse, reason: 'nothing to probe yet');
  });

  // Each outcome gets the sentence that names the actual problem. The whole
  // point of probing before storing: an unverified URL leaves somebody staring
  // at a login form that can never succeed, with nothing on screen to say why.
  testWidgets('an unreachable server says so', (tester) async {
    await pumpWith(tester, (_) async => throw ClientException());
    await tester.enterText(find.byType(TextFormField), 'pigeons.example');
    await tester.tap(find.text(de.setupConnectAction));
    await tester.pumpAndSettle();
    expect(find.text(de.setupErrorUnreachable), findsOneWidget);
  });

  testWidgets('something that is not this app says THAT', (tester) async {
    // A generic PocketBase, an unrelated 200 — or federfall's backend.
    await pumpWith(tester, (_) async => {'service': 'federfall'});
    await tester.enterText(find.byType(TextFormField), 'pigeons.example');
    await tester.tap(find.text(de.setupConnectAction));
    await tester.pumpAndSettle();
    expect(find.text(de.setupErrorWrongService), findsOneWidget);
  });

  testWidgets('a cleartext http address is refused with the reason', (
    tester,
  ) async {
    // Not "could not connect": the password would travel in the clear, and the
    // OS would have blocked it anyway with an opaque failure.
    await pumpWith(tester, (_) async => {'service': 'eiermann'});
    await tester.enterText(
      find.byType(TextFormField),
      'http://pigeons.example',
    );
    await tester.tap(find.text(de.setupConnectAction));
    await tester.pumpAndSettle();
    expect(find.text(de.setupErrorInsecure), findsOneWidget);
  });

  testWidgets('a real server is accepted, and the button keeps spinning', (
    tester,
  ) async {
    var probedWith = '';
    await pumpWith(tester, (url) async {
      probedWith = url;
      return {'service': 'eiermann', 'version': '1.0.0'};
    });
    await tester.enterText(find.byType(TextFormField), 'pigeons.example');
    await tester.tap(find.text(de.setupConnectAction));
    // Bounded pumps, NOT pumpAndSettle: on success the screen deliberately
    // leaves the button spinning, because the router's gate is about to replace
    // it — and a spinner never settles. A pumpAndSettle here times out, which
    // is the test discovering the intended behaviour the hard way.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // The address reached the probe with `https://` ALREADY ADDED. That is the
    // behaviour worth pinning: somebody typing a bare hostname gets https, not
    // a scheme-less request that fails for a reason they cannot act on — and
    // not http, which would send the password in the clear.
    expect(probedWith, 'https://pigeons.example');
    expect(find.text(de.setupErrorUnreachable), findsNothing);
    expect(find.text(de.setupErrorWrongService), findsNothing);
    expect(find.text(de.setupErrorInvalidUrl), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
