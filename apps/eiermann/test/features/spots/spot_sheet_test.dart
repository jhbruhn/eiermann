import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/spots/spot_sheet.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/harness.dart';

class _MockSpots extends Mock implements SpotsRepository {}

/// A host with one button, so the sheet is opened the way the app opens it —
/// through `showAppSheet`. The discard guard hangs off `Navigator.maybePop`,
/// which only exists for a route that was actually pushed.
class _Host extends StatelessWidget {
  const _Host();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ElevatedButton(
        onPressed: () => showSpotSheet(context),
        child: const Text('open'),
      ),
    ),
  );
}

void main() {
  late AppLocalizations de;
  late _MockSpots spots;

  setUpAll(() async {
    de = await germanStrings();
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() {
    spots = _MockSpots();
    when(() => spots.create(any())).thenAnswer(
      (_) async => const Spot(id: 's-new', name: 'Bahnhofstraße 12'),
    );
  });

  Future<void> openSheet(WidgetTester tester) async {
    // Six fields plus the save button do not fit the default 800x600 test
    // window, and a tap landing a few pixels below the fold is a harness
    // artefact, not a finding about the sheet.
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpApp(
      const _Host(),
      overrides: [
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
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('a Spot without a name is refused before any request', (
    tester,
  ) async {
    // The name is the identity: a Spot called nothing cannot be found again,
    // and the server would refuse it anyway — better here, where the field is
    // still on screen.
    await openSheet(tester);
    await tester.tap(find.text(de.actionSave));
    await tester.pumpAndSettle();

    expect(find.text(de.fieldRequired), findsOneWidget);
    verifyNever(() => spots.create(any()));
  });

  testWidgets('a named Spot is created, and the sheet closes', (tester) async {
    await openSheet(tester);
    await tester.enterText(
      find.widgetWithText(TextFormField, de.spotFieldName),
      'Bahnhofstraße 12',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, de.spotFieldAccessNote),
      'Klingel Hausmeister Kröger',
    );
    await tester.tap(find.text(de.actionSave));
    await tester.pumpAndSettle();

    final body =
        verify(() => spots.create(captureAny())).captured.single
            as Map<String, dynamic>;
    expect(body['name'], 'Bahnhofstraße 12');
    expect(body['access_note'], 'Klingel Hausmeister Kröger');
    // A new Spot starts as an Erkundung: somebody walked past a building and
    // there is no permission yet.
    expect(body['phase'], SpotPhase.prospect.wire);
    // Pinned to the caller's own org — the one write that could cross tenancy.
    expect(body['org'], 'org00000default');
    expect(find.text(de.spotSheetTitleNew), findsNothing);
  });

  testWidgets('dismissing a sheet with unsaved input asks before losing it', (
    tester,
  ) async {
    await openSheet(tester);
    await tester.enterText(
      find.widgetWithText(TextFormField, de.spotFieldName),
      'Halb getippt',
    );
    await tester.pumpAndSettle();

    // A tap on the scrim outside the sheet routes through Navigator.maybePop,
    // which is what the guard intercepts.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text(de.discardChangesTitle), findsOneWidget);
    // Still open behind the dialog: nothing is thrown away until the answer.
    expect(find.text(de.spotSheetTitleNew), findsOneWidget);
  });

  testWidgets('keeping the edit leaves the input where it was', (tester) async {
    await openSheet(tester);
    await tester.enterText(
      find.widgetWithText(TextFormField, de.spotFieldName),
      'Halb getippt',
    );
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.text(de.discardKeepEditing));
    await tester.pumpAndSettle();

    expect(find.text(de.spotSheetTitleNew), findsOneWidget);
    expect(find.text('Halb getippt'), findsOneWidget);
  });

  testWidgets('an UNTOUCHED sheet closes on a scrim tap without a prompt', (
    tester,
  ) async {
    // The guard only earns its interruption when there is something to lose.
    await openSheet(tester);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text(de.discardChangesTitle), findsNothing);
    expect(find.text(de.spotSheetTitleNew), findsNothing);
  });

  testWidgets('a rejected write keeps the sheet open and says why', (
    tester,
  ) async {
    // The entry must survive the failure: retyping an address because the
    // server was briefly unreachable is exactly the kind of loss the copy
    // promises will not happen.
    when(() => spots.create(any())).thenThrow(
      const RepositoryException('down', kind: RepositoryErrorKind.network),
    );
    await openSheet(tester);
    await tester.enterText(
      find.widgetWithText(TextFormField, de.spotFieldName),
      'Bahnhofstraße 12',
    );
    await tester.tap(find.text(de.actionSave));
    await tester.pumpAndSettle();

    expect(find.text(de.errorOffline), findsOneWidget);
    expect(find.text('Bahnhofstraße 12'), findsOneWidget);
  });
}
