import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/spots/spot_phase_chip.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/harness.dart';

class _MockSpots extends Mock implements SpotsRepository {}

/// Hosts the chip the way the dossier does, so the menu opens through a real
/// route and the sheet it pushes has a Navigator to pop.
class _Host extends StatelessWidget {
  const _Host(this.spot);

  final Spot spot;

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: SpotPhaseChip(spot)));
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
    when(
      () => spots.update(any(), any()),
    ).thenAnswer((_) async => const Spot(id: 's1', name: 'Bahnhofstraße 12'));
  });

  Future<void> pumpChip(WidgetTester tester, Spot spot) async {
    // The sheet's explanation, its fields and the button do not fit the default
    // 800x600, and a tap landing below the fold is a harness artefact rather
    // than a finding about the sheet.
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpApp(
      _Host(spot),
      overrides: [spotsRepositoryProvider.overrideWith((ref) async => spots)],
    );
  }

  Future<void> openMenu(WidgetTester tester, Spot spot) async {
    await pumpChip(tester, spot);
    await tester.tap(find.byType(SpotPhaseChip));
    await tester.pumpAndSettle();
  }

  /// The body of the single update the sheet sent.
  Map<String, dynamic> writtenBody() =>
      verify(() => spots.update(any(), captureAny())).captured.single
          as Map<String, dynamic>;

  const prospect = Spot(
    id: 's1',
    name: 'Bahnhofstraße 12',
    street: 'Bahnhofstraße 12',
    city: 'Oldenburg',
    phase: SpotPhase.prospect,
    prospectStage: ProspectStage.ownerSpoken,
  );
  final active = prospect.copyWith(
    phase: SpotPhase.active,
    prospectStage: ProspectStage.permitted,
  );
  final paused = active.copyWith(
    phase: SpotPhase.paused,
    pauseReason: 'Gerüst',
    pausedUntil: DateTime.utc(2026, 10, 31),
  );
  final closedSpot = active.copyWith(
    phase: SpotPhase.closed,
    closedReason: ClosedReason.netted,
    closedAt: DateTime.utc(2026, 8, 3),
  );

  group('the phase menu offers only the moves the server accepts', () {
    testWidgets('an Erkundung: activate or close, never pause', (tester) async {
      await openMenu(tester, prospect);

      expect(find.text(de.spotMoveActivate), findsOneWidget);
      expect(find.text(de.spotMoveClose), findsOneWidget);
      // There is nothing to pause: an Erkundung either continues or ends.
      expect(find.text(de.spotMovePause), findsNothing);
    });

    testWidgets('an active Spot: pause or close, never back to Erkundung', (
      tester,
    ) async {
      await openMenu(tester, active);

      expect(find.text(de.spotMovePause), findsOneWidget);
      expect(find.text(de.spotMoveClose), findsOneWidget);
      // Permission once obtained is not un-learned.
      expect(find.text(de.spotPhaseProspect), findsNothing);
    });

    testWidgets('a paused Spot: resume, close, or correct the pause', (
      tester,
    ) async {
      await openMenu(tester, paused);

      expect(find.text(de.spotMoveResume), findsOneWidget);
      expect(find.text(de.spotMoveClose), findsOneWidget);
      // Not a transition, and the reason it exists: correcting an end date must
      // not have to be spelled as resume-then-pause-again.
      expect(find.text(de.spotMoveEditPause), findsOneWidget);
      // "Pausieren" would be a move to the phase it is already in.
      expect(find.text(de.spotMovePause), findsNothing);
    });

    testWidgets('a closed Spot: reopen, and nothing else', (tester) async {
      await openMenu(tester, closedSpot);

      expect(find.text(de.spotMoveReopen), findsOneWidget);
      // "closed, then paused" is a state nobody can act on, so the way back is
      // through active — two steps, and only the first is offered here.
      expect(find.text(de.spotMovePause), findsNothing);
      expect(find.text(de.spotMoveClose), findsNothing);
    });

    testWidgets('a phase this build cannot name offers no move at all', (
      tester,
    ) async {
      // A server that gained a fifth phase. Guessing which moves it permits
      // means offering a refusal.
      await pumpChip(tester, prospect.copyWith(phase: null));
      await tester.tap(find.byType(SpotPhaseChip));
      await tester.pumpAndSettle();

      expect(find.text(de.spotPhaseUnknown), findsOneWidget);
      expect(find.text(de.spotMoveActivate), findsNothing);
      verifyNever(() => spots.update(any(), any()));
    });
  });

  group('pausing', () {
    testWidgets('is refused without a reason, before any request', (
      tester,
    ) async {
      await openMenu(tester, active);
      await tester.tap(find.text(de.spotMovePause));
      await tester.pumpAndSettle();
      await tester.tap(find.text(de.spotMovePause).last);
      await tester.pumpAndSettle();

      expect(find.text(de.fieldRequired), findsOneWidget);
      verifyNever(() => spots.update(any(), any()));
    });

    testWidgets('sends the reason and leaves the address alone', (
      tester,
    ) async {
      await openMenu(tester, active);
      await tester.tap(find.text(de.spotMovePause));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, de.spotPauseFieldReason),
        'Gerüst bis Ende Oktober',
      );
      await tester.tap(find.text(de.spotMovePause).last);
      await tester.pumpAndSettle();

      final body = writtenBody();
      expect(body['phase'], SpotPhase.paused.wire);
      expect(body['pause_reason'], 'Gerüst bis Ende Oktober');
      // No planned end was picked, and it is sent as empty rather than omitted:
      // correcting a pause has to be able to REMOVE the date.
      expect(body['paused_until'], '');
      // The phase body carries the phase and nothing else. A form's body would
      // have wiped the street off a Spot somebody only meant to pause.
      expect(body.containsKey('street'), isFalse);
      expect(body.containsKey('name'), isFalse);
    });

    testWidgets('a correction starts from the pause that is running', (
      tester,
    ) async {
      await openMenu(tester, paused);
      await tester.tap(find.text(de.spotMoveEditPause));
      await tester.pumpAndSettle();

      expect(find.text('Gerüst'), findsOneWidget);
      expect(find.text(de.spotPauseEditTitle), findsOneWidget);
    });
  });

  group('closing', () {
    testWidgets('is refused without a reason, before any request', (
      tester,
    ) async {
      // "Closed" alone cannot answer the only question anybody asks of a closed
      // Spot six months on: do we try again?
      await openMenu(tester, active);
      await tester.tap(find.text(de.spotMoveClose));
      await tester.pumpAndSettle();
      await tester.tap(find.text(de.spotMoveClose).last);
      await tester.pumpAndSettle();

      expect(find.text(de.fieldRequired), findsOneWidget);
      verifyNever(() => spots.update(any(), any()));
    });

    testWidgets('sends the chosen reason', (tester) async {
      await openMenu(tester, active);
      await tester.tap(find.text(de.spotMoveClose));
      await tester.pumpAndSettle();
      await tester.tap(find.text(de.spotCloseFieldReason));
      await tester.pumpAndSettle();
      await tester.tap(find.text(de.closedReasonNetted).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(de.spotMoveClose).last);
      await tester.pumpAndSettle();

      final body = writtenBody();
      expect(body['phase'], SpotPhase.closed.wire);
      expect(body['closed_reason'], ClosedReason.netted.wire);
      // Server-owned: a client that can write the closing date can backdate a
      // decision nobody made.
      expect(body.containsKey('closed_at'), isFalse);
    });

    testWidgets('a REFUSED Erkundung closes without one', (tester) async {
      // The refusal is already recorded in the field built for it, and none of
      // the four closing reasons describes an owner who simply said no.
      final refused = prospect.copyWith(prospectStage: ProspectStage.refused);
      await openMenu(tester, refused);
      await tester.tap(find.text(de.spotMoveClose));
      await tester.pumpAndSettle();

      expect(find.text(de.spotCloseRefusedNote), findsOneWidget);
      await tester.tap(find.text(de.spotMoveClose).last);
      await tester.pumpAndSettle();

      final body = writtenBody();
      expect(body['phase'], SpotPhase.closed.wire);
      expect(body['closed_reason'], '');
    });
  });

  group('activating an Erkundung', () {
    testWidgets('needs the Zusage, and says what is at stake without it', (
      tester,
    ) async {
      await openMenu(tester, prospect);
      await tester.tap(find.text(de.spotMoveActivate));
      await tester.pumpAndSettle();
      await tester.tap(find.text(de.spotMoveActivate).last);
      await tester.pumpAndSettle();

      expect(find.text(de.spotActivateConsentRequired), findsOneWidget);
      verifyNever(() => spots.update(any(), any()));
    });

    testWidgets('records the Zusage in the same write as the phase', (
      tester,
    ) async {
      // One request, not two: a client that set the stage first and the phase
      // afterwards can be interrupted between them, leaving a Spot whose funnel
      // claims a permission nobody acted on.
      await openMenu(tester, prospect);
      await tester.tap(find.text(de.spotMoveActivate));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.tap(find.text(de.spotMoveActivate).last);
      await tester.pumpAndSettle();

      final body = writtenBody();
      expect(body['phase'], SpotPhase.active.wire);
      expect(body['prospect_stage'], ProspectStage.permitted.wire);
    });

    testWidgets('asks nothing more once the Erkundung already said yes', (
      tester,
    ) async {
      final permitted = prospect.copyWith(
        prospectStage: ProspectStage.permitted,
      );
      await openMenu(tester, permitted);
      await tester.tap(find.text(de.spotMoveActivate));
      await tester.pumpAndSettle();

      expect(find.byType(Checkbox), findsNothing);
      await tester.tap(find.text(de.spotMoveActivate).last);
      await tester.pumpAndSettle();

      final body = writtenBody();
      expect(body['phase'], SpotPhase.active.wire);
      // Nothing rewrites a funnel that already says yes.
      expect(body.containsKey('prospect_stage'), isFalse);
    });
  });

  group('resuming and reopening', () {
    testWidgets('a resume says what it is about to erase', (tester) async {
      // A sheet whose only content is a button is a confirmation that confirms
      // nothing — and this one silently deletes a reason somebody wrote.
      await openMenu(tester, paused);
      await tester.tap(find.text(de.spotMoveResume));
      await tester.pumpAndSettle();

      expect(find.text(de.spotResumeIntro), findsOneWidget);
      await tester.tap(find.text(de.spotMoveResume).last);
      await tester.pumpAndSettle();

      final body = writtenBody();
      expect(body['phase'], SpotPhase.active.wire);
      // The hook clears pause_reason and paused_until itself. Clearing them
      // here as well would be a second copy of that rule.
      expect(body.containsKey('pause_reason'), isFalse);
      expect(body.containsKey('paused_until'), isFalse);
    });

    testWidgets('a reopen sends nothing but the phase', (tester) async {
      await openMenu(tester, closedSpot);
      await tester.tap(find.text(de.spotMoveReopen));
      await tester.pumpAndSettle();
      await tester.tap(find.text(de.spotMoveReopen).last);
      await tester.pumpAndSettle();

      expect(writtenBody(), {'phase': SpotPhase.active.wire});
    });
  });

  testWidgets('a refusal from the server keeps the sheet open and says why', (
    tester,
  ) async {
    // The whole point of this sheet: the hook's German reaches the user, on the
    // surface that can act on it. Before it existed, the edit sheet offered the
    // move and the user read a refusal they had no way to answer.
    when(() => spots.update(any(), any())).thenThrow(
      const RepositoryException(
        'refused',
        kind: RepositoryErrorKind.validation,
        // The channel a deliberate hook refusal arrives on. PocketBase's own
        // English boilerplate never sets it, which is why this one reaches the
        // user verbatim while a field-validation 400 still gets app copy.
        serverMessage: 'Eine Pause braucht einen Grund.',
      ),
    );
    await openMenu(tester, active);
    await tester.tap(find.text(de.spotMovePause));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, de.spotPauseFieldReason),
      'Gerüst',
    );
    await tester.tap(find.text(de.spotMovePause).last);
    await tester.pumpAndSettle();

    expect(find.text('Eine Pause braucht einen Grund.'), findsOneWidget);
    // Still open: the input survives the failure.
    expect(find.text(de.spotPauseTitle), findsOneWidget);
    expect(find.text('Gerüst'), findsOneWidget);
  });
}
