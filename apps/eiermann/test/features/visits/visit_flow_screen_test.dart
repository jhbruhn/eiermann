import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/visits/visit_flow_screen.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/harness.dart';

class _MockVisits extends Mock implements VisitsRepository {}

class _MockNestState extends Mock implements NestStateRepository {}

class _MockEggs extends Mock implements NestEggsRepository {}

NestState nestRow({String id = 'n1', String label = 'N1'}) => NestState(
  id: id,
  label: label,
  area: 'a1',
  urgency: 3,
  spot: 's1',
);

void main() {
  late AppLocalizations de;
  late _MockVisits visits;
  late _MockNestState nestStates;
  late _MockEggs eggs;

  setUpAll(() async {
    de = await germanStrings();
    registerFallbackValue(
      const VisitDraft(spot: 's1', outcome: VisitOutcome.checked),
    );
  });

  setUp(() {
    visits = _MockVisits();
    nestStates = _MockNestState();
    eggs = _MockEggs();
    when(() => nestStates.forSpot(any())).thenAnswer((_) async => [nestRow()]);
    when(() => eggs.forNest(any())).thenAnswer(
      (_) async => [
        NestEgg(
          id: 'e0',
          nest: 'n1',
          kind: EggKind.real,
          since: DateTime.now(),
        ),
      ],
    );
    when(
      () => visits.submit(any(), idempotencyKey: any(named: 'idempotencyKey')),
    ).thenAnswer(
      (_) async => const VisitResult(visit: 'v1'),
    );
  });

  Future<void> pump(WidgetTester tester, {bool skipped = false}) async {
    // A TALL test surface, deliberately. The flow is one scroll view, and a
    // `ListView` does not build what is below the fold — so on the default
    // 800x600 surface the finish button drops out of the tree the moment the
    // failure card above it appears, and the test reads as "the retry button is
    // missing" when the screen is simply scrolled.
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpApp(
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    VisitFlowScreen(spotId: 's1', startSkipped: skipped),
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ),
      overrides: [
        visitsRepositoryProvider.overrideWith((ref) async => visits),
        nestStateRepositoryProvider.overrideWith((ref) async => nestStates),
        nestEggsRepositoryProvider.overrideWith((ref) async => eggs),
      ],
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  /// Records the one nest through the check sheet, swapping its real egg.
  Future<void> recordNest(WidgetTester tester) async {
    await tester.tap(find.text('N1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(de.nestCheckSwapAllAction));
    await tester.pumpAndSettle();
    final apply = find.text(de.nestCheckApplyAction);
    await tester.ensureVisible(apply);
    await tester.pumpAndSettle();
    await tester.tap(apply);
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, String label) async {
    final button = find.text(label);
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('the nests of the building are the work list', (tester) async {
    when(() => nestStates.forSpot('s1')).thenAnswer(
      (_) async => [nestRow(), nestRow(id: 'n2', label: 'N2')],
    );

    await pump(tester);

    expect(find.text('N1'), findsOneWidget);
    expect(find.text('N2'), findsOneWidget);
    // Nothing recorded yet, and "offen" is deliberately not "nicht geprüft" —
    // that is a different, recorded outcome.
    expect(find.text(de.visitFlowNestOpen), findsNWidgets(2));
    expect(find.text(de.visitFlowProgress(0, 2)), findsOneWidget);
  });

  testWidgets('a recorded nest shows what was done, not what was in it', (
    tester,
  ) async {
    await pump(tester);
    await recordNest(tester);

    expect(find.text(de.checkStateSwapped), findsOneWidget);
    expect(find.text(de.visitFlowProgress(1, 1)), findsOneWidget);
    // Nothing has been written yet: the whole visit goes in one request.
    verifyNever(
      () => visits.submit(any(), idempotencyKey: any(named: 'idempotencyKey')),
    );
  });

  testWidgets('finishing writes the WHOLE visit in one request', (
    tester,
  ) async {
    // Seven REST writes that break after the second leave a visit in which five
    // nests were not checked — indistinguishable from five nests somebody chose
    // not to touch.
    await pump(tester);
    await recordNest(tester);
    await press(tester, de.visitFlowFinishAction);

    final captured = verify(
      () => visits.submit(
        captureAny(),
        idempotencyKey: captureAny(named: 'idempotencyKey'),
      ),
    ).captured;
    expect(captured.length, 2, reason: 'exactly one call, two captures');
    final draft = captured.first as VisitDraft;
    expect(draft.outcome, VisitOutcome.checked);
    expect(draft.checks.single.removedReal, 1);
    // And the screen is gone — the confirmation is a snackbar over the dossier.
    expect(find.byType(VisitFlowScreen), findsNothing);
  });

  testWidgets('a failed send keeps the visit and says nothing is lost', (
    tester,
  ) async {
    // A volunteer who thinks the work is gone stops recording, so the copy has
    // to say the visit is still here.
    when(
      () => visits.submit(any(), idempotencyKey: any(named: 'idempotencyKey')),
    ).thenAnswer((_) async => throw const RepositoryException('nope'));

    await pump(tester);
    await recordNest(tester);
    await press(tester, de.visitFlowFinishAction);

    expect(find.byType(VisitFlowScreen), findsOneWidget);
    expect(find.text(de.visitFlowSendFailedTitle), findsOneWidget);
    expect(find.text(de.visitFlowSendFailedHint), findsOneWidget);
    // The recorded nest is still recorded.
    expect(find.text(de.checkStateSwapped), findsOneWidget);
  });

  testWidgets('the retry reuses the SAME key — three presses, one visit', (
    tester,
  ) async {
    // The entire safety property of the retry button. A fresh key per attempt
    // would turn "press it three times" into three visits, three sets of checks
    // and a rhythm advanced three times.
    when(
      () => visits.submit(any(), idempotencyKey: any(named: 'idempotencyKey')),
    ).thenAnswer((_) async => throw const RepositoryException('nope'));

    await pump(tester);
    await recordNest(tester);
    await press(tester, de.visitFlowFinishAction);
    await press(tester, de.visitFlowRetryAction);
    await press(tester, de.visitFlowRetryAction);

    final keys = verify(
      () => visits.submit(
        any(),
        idempotencyKey: captureAny(named: 'idempotencyKey'),
      ),
    ).captured;
    expect(keys.length, 3);
    expect(keys.toSet().length, 1, reason: 'one key for one visit');
  });

  testWidgets('an unknown outcome still offers the retry', (tester) async {
    // A client-side timeout abandons the request but cannot cancel it, so the
    // visit may have landed. The key is what makes pressing again right anyway.
    when(
      () => visits.submit(any(), idempotencyKey: any(named: 'idempotencyKey')),
    ).thenAnswer(
      (_) async => throw const RepositoryException(
        'timeout',
        kind: RepositoryErrorKind.unknownOutcome,
      ),
    );

    await pump(tester);
    await recordNest(tester);
    await press(tester, de.visitFlowFinishAction);

    expect(find.text(de.visitFlowRetryAction), findsOneWidget);
    expect(find.text(de.visitFlowSendFailedHint), findsOneWidget);
  });

  testWidgets('"nicht geprüft" needs a reason and carries no checks', (
    tester,
  ) async {
    // A skipped visit documents a non-event. A check inside one would be an
    // observation, and the rhythm would advance on a nest nobody saw.
    await pump(tester, skipped: true);

    expect(find.text(de.visitSkipHint), findsOneWidget);
    await press(tester, de.visitSkipConfirmAction);
    // Refused in the form: without a reason the record cannot say whether
    // anybody tried.
    expect(find.text(de.visitSkipReasonMissing), findsOneWidget);
    verifyNever(
      () => visits.submit(any(), idempotencyKey: any(named: 'idempotencyKey')),
    );

    await press(tester, de.skipReasonNoKey);
    await press(tester, de.visitSkipConfirmAction);

    final captured = verify(
      () => visits.submit(
        captureAny(),
        idempotencyKey: captureAny(named: 'idempotencyKey'),
      ),
    ).captured;
    final draft = captured.first as VisitDraft;
    expect(draft.outcome, VisitOutcome.skipped);
    expect(draft.skipReason, SkipReason.noKey);
    expect(draft.checks, isEmpty);
  });

  testWidgets('a building with no nests can still be visited', (tester) async {
    // Empty does not mean done: going there and finding nothing to check is a
    // visit, and the server dates the Spot from it.
    when(() => nestStates.forSpot('s1')).thenAnswer((_) async => []);

    await pump(tester);

    expect(find.text(de.visitFlowNoNests), findsOneWidget);
    await press(tester, de.visitFlowFinishAction);

    final captured = verify(
      () => visits.submit(
        captureAny(),
        idempotencyKey: captureAny(named: 'idempotencyKey'),
      ),
    ).captured;
    expect((captured.first as VisitDraft).checks, isEmpty);
  });

  testWidgets('the retry after a failed skip resends the SKIP', (tester) async {
    // One key belongs to one body. Retrying a failed "nicht geprüft" with a
    // *checked* visit under the same key is the 409 the retry exists to avoid —
    // and the volunteer would be reading "your key is being reused" for having
    // pressed the button the app offered them.
    when(
      () => visits.submit(any(), idempotencyKey: any(named: 'idempotencyKey')),
    ).thenAnswer((_) async => throw const RepositoryException('nope'));

    await pump(tester, skipped: true);
    await press(tester, de.skipReasonNobodyThere);
    await press(tester, de.visitSkipConfirmAction);
    await press(tester, de.visitFlowRetryAction);

    final captured = verify(
      () => visits.submit(
        captureAny(),
        idempotencyKey: captureAny(named: 'idempotencyKey'),
      ),
    ).captured;
    final drafts = captured.whereType<VisitDraft>().toList();
    final keys = captured.whereType<String>().toSet();
    expect(drafts.length, 2);
    expect(drafts.every((d) => d.outcome == VisitOutcome.skipped), isTrue);
    expect(drafts.last.skipReason, SkipReason.nobodyThere);
    expect(keys.length, 1, reason: 'one key for one visit');
  });

  testWidgets('a pending attempt withdraws the OTHER outcome', (tester) async {
    // Same reason: the key is committed to that body now. The way out of a
    // failed send is the retry, or leaving.
    when(
      () => visits.submit(any(), idempotencyKey: any(named: 'idempotencyKey')),
    ).thenAnswer((_) async => throw const RepositoryException('nope'));

    await pump(tester);
    await recordNest(tester);
    await press(tester, de.visitFlowFinishAction);

    final skip = find.widgetWithText(OutlinedButton, de.visitSkipAction);
    expect(tester.widget<OutlinedButton>(skip).onPressed, isNull);
  });

  /// Taps the kind chip inside the open Fund sheet.
  ///
  /// Through the CHIP and not through the text: once a Fund is recorded, the
  /// flow's list below shows the same words, and `find.text` would match both.
  Future<void> chooseKind(WidgetTester tester, String kind) async {
    final chip = find.widgetWithText(ChoiceChip, kind);
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await tester.pumpAndSettle();
  }

  /// Records one Fund of [kind] through the sheet.
  Future<void> recordFinding(WidgetTester tester, String kind) async {
    await press(tester, de.findingsAddAction);
    await chooseKind(tester, kind);
    await press(tester, de.findingApplyAction);
  }

  testWidgets('nothing found is said out loud, not left blank', (tester) async {
    // A volunteer who believes every visit needs a Fund will invent one, so the
    // empty state states that nothing found is the normal case.
    await pump(tester);

    expect(find.text(de.findingsTitle), findsOneWidget);
    expect(find.text(de.findingsNone), findsOneWidget);
  });

  testWidgets('the Fund kind has no default — saving without one is refused', (
    tester,
  ) async {
    // Starting on "Toter Vogel" would mean a stray tap records a dead bird, and
    // a Fund is a fact about a building that reaches a report to an authority.
    await pump(tester);
    await press(tester, de.findingsAddAction);
    await press(tester, de.findingApplyAction);

    expect(find.text(de.findingKindMissing), findsOneWidget);
    // The sheet is still open, and the entry does not exist.
    expect(find.text(de.findingKindQuestion), findsOneWidget);
  });

  testWidgets('a Fund travels in the SAME body as the checks', (tester) async {
    await pump(tester);
    await recordNest(tester);
    await recordFinding(tester, de.findingKindDeadBird);

    // Recorded on the flow, not written yet: one visit, one request.
    expect(find.text(de.findingKindDeadBird), findsOneWidget);
    verifyNever(
      () => visits.submit(any(), idempotencyKey: any(named: 'idempotencyKey')),
    );

    await press(tester, de.visitFlowFinishAction);

    final captured = verify(
      () => visits.submit(
        captureAny(),
        idempotencyKey: captureAny(named: 'idempotencyKey'),
      ),
    ).captured;
    final draft = captured.first as VisitDraft;
    expect(draft.checks.length, 1);
    expect(draft.findings.single.kind, FindingKind.deadBird);
    expect(draft.findings.single.count, 1);
  });

  testWidgets('two Funde of the same kind are two entries', (tester) async {
    // A list and not a map: two dead pigeons in two corners of the same loft
    // are two entries, and keying them by kind would make the second overwrite
    // the first without saying so.
    await pump(tester);
    await recordFinding(tester, de.findingKindDeadBird);
    await recordFinding(tester, de.findingKindDeadBird);
    await press(tester, de.visitFlowFinishAction);

    final draft =
        verify(
              () => visits.submit(
                captureAny(),
                idempotencyKey: any(named: 'idempotencyKey'),
              ),
            ).captured.first
            as VisitDraft;
    expect(draft.findings.length, 2);
  });

  testWidgets('discarding a Fund removes it', (tester) async {
    // Null from an EXISTING entry means "discard", and it has to actually
    // remove the row — a stale draft left behind would record something nobody
    // confirmed.
    await pump(tester);
    await recordFinding(tester, de.findingKindChick);
    expect(find.text(de.findingKindChick), findsOneWidget);

    await tester.tap(find.text(de.findingKindChick));
    await tester.pumpAndSettle();
    await press(tester, de.findingDiscardAction);

    expect(find.text(de.findingsNone), findsOneWidget);
    await press(tester, de.visitFlowFinishAction);
    final draft =
        verify(
              () => visits.submit(
                captureAny(),
                idempotencyKey: any(named: 'idempotencyKey'),
              ),
            ).captured.first
            as VisitDraft;
    expect(draft.findings, isEmpty);
  });

  testWidgets('a "nicht geprüft" visit still carries its Funde', (
    tester,
  ) async {
    // "Netz an der Nordseite, nicht mehr reingekommen" is a non-event whose
    // REASON is a Fund, seen from outside. The endpoint accepts findings on a
    // skip and refuses checks, and this form must not be stricter than it: the
    // alternative is nowhere to record why somebody turned round.
    await pump(tester);
    await recordFinding(tester, de.findingKindSiteChange);
    await press(tester, de.visitSkipAction);
    await press(tester, de.skipReasonAccessBlocked);
    await press(tester, de.visitSkipConfirmAction);

    final draft =
        verify(
              () => visits.submit(
                captureAny(),
                idempotencyKey: any(named: 'idempotencyKey'),
              ),
            ).captured.first
            as VisitDraft;
    expect(draft.outcome, VisitOutcome.skipped);
    expect(draft.checks, isEmpty);
    expect(draft.findings.single.kind, FindingKind.siteChange);
  });

  testWidgets('a Fund can name the nest it belongs to', (tester) async {
    // Optional, and the option is the point: a dead bird on the floor belongs
    // to no nest. When it IS about one, the label rides along, because an id
    // with no label next to it is a bug in this app.
    await pump(tester);
    await press(tester, de.findingsAddAction);
    await chooseKind(tester, de.findingKindChick);
    await tester.tap(find.text(de.findingNestNone));
    await tester.pumpAndSettle();
    await tester.tap(find.text('N1').last);
    await tester.pumpAndSettle();
    await press(tester, de.findingApplyAction);
    await press(tester, de.visitFlowFinishAction);

    final draft =
        verify(
              () => visits.submit(
                captureAny(),
                idempotencyKey: any(named: 'idempotencyKey'),
              ),
            ).captured.first
            as VisitDraft;
    expect(draft.findings.single.nest, 'n1');
    expect(draft.findings.single.nestLabel, 'N1');
  });
}
