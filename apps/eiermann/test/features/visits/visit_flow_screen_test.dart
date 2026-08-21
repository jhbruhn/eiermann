import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/areas/pin_canvas.dart';
import 'package:eiermann/features/nests/nest_labels.dart';
import 'package:eiermann/features/visits/check_labels.dart';
import 'package:eiermann/features/visits/visit_area_group.dart';
import 'package:eiermann/features/visits/visit_flow_screen.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/routing/router.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/harness.dart';

class _MockVisits extends Mock implements VisitsRepository {}

class _MockNestState extends Mock implements NestStateRepository {}

class _MockEggs extends Mock implements NestEggsRepository {}

class _MockSpots extends Mock implements SpotsRepository {}

class _MockAreas extends Mock implements AreasRepository {}

NestState nestRow({
  String id = 'n1',
  String label = 'N1',
  String area = 'a1',
  double? pinX,
  double? pinY,
}) => NestState(
  id: id,
  label: label,
  area: area,
  urgency: 3,
  spot: 's1',
  species: NestSpecies.feralPigeon,
  pinX: pinX,
  pinY: pinY,
);

/// The Bereich the nests sit in. Without a photo by default, and that is not
/// laziness: an image never resolves in a widget test, so a photo on every pump
/// would leave `pumpAndSettle` waiting on a placeholder forever. The tests that
/// need the picture ask for it and settle in bounded pumps.
const bereich = Area(id: 'a1', name: 'Dachboden Nord', spot: 's1');

const bereichWithPhoto = Area(
  id: 'a1',
  name: 'Dachboden Nord',
  spot: 's1',
  photo: 'dachboden.jpg',
);

/// Bounded pumps: an image that never loads keeps a placeholder animating, and
/// `pumpAndSettle` would wait for it forever.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late AppLocalizations de;
  late _MockVisits visits;
  late _MockNestState nestStates;
  late _MockEggs eggs;
  late _MockSpots spots;
  late _MockAreas areas;

  /// The building, as the closing offer re-reads it after the write.
  const spot = Spot(
    id: 's1',
    name: 'Bahnhofstraße 12',
    phase: SpotPhase.active,
  );

  setUpAll(() async {
    de = await germanStrings();
    registerFallbackValue(
      const VisitDraft(spot: 's1', outcome: VisitOutcome.checked),
    );
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() {
    visits = _MockVisits();
    nestStates = _MockNestState();
    eggs = _MockEggs();
    spots = _MockSpots();
    areas = _MockAreas();
    when(() => areas.forSpot(any())).thenAnswer((_) async => [bereich]);
    when(
      () => areas.fileUrl(
        any(),
        any(),
        thumb: any(named: 'thumb'),
        token: any(named: 'token'),
      ),
    ).thenAnswer(
      (i) => Uri.parse(
        'http://pb.test/api/files/areas/${i.positionalArguments[0]}'
        '/${i.positionalArguments[1]}',
      ),
    );
    when(() => spots.getOne(any())).thenAnswer((_) async => spot);
    when(() => spots.update(any(), any())).thenAnswer((_) async => spot);
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

  Future<void> pump(
    WidgetTester tester, {
    bool skipped = false,
    Size surface = const Size(1200, 3000),
  }) async {
    // A TALL test surface, deliberately. The flow is one scroll view, and a
    // `ListView` does not build what is below the fold — so on the default
    // 800x600 surface the finish button drops out of the tree the moment the
    // failure card above it appears, and the test reads as "the retry button is
    // missing" when the screen is simply scrolled.
    tester.view.physicalSize = surface;
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
        spotsRepositoryProvider.overrideWith((ref) async => spots),
        areasRepositoryProvider.overrideWith((ref) async => areas),
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
    // The structural change offers the closing here too, and it should: "Netz
    // an der Nordseite, nicht mehr reingekommen" is exactly the visit after
    // which somebody decides. Declined, so this test stays about the body.
    await press(tester, de.findingCloseOfferDismiss);

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

  testWidgets('a structural change offers the closing AFTER the write', (
    tester,
  ) async {
    // The order is the point. A netted building is a fact; closing the Spot is
    // a decision about the programme, and the second does not follow from the
    // first without somebody saying so. So the Fund is written first and the
    // question comes second — a volunteer who declines has still recorded what
    // they saw.
    await pump(tester);
    await recordFinding(tester, de.findingKindSiteChange);
    await press(tester, de.visitFlowFinishAction);

    verify(
      () => visits.submit(any(), idempotencyKey: any(named: 'idempotencyKey')),
    ).called(1);
    expect(find.text(de.findingCloseOfferTitle), findsOneWidget);
    // Declining leaves the Spot exactly as it was.
    await press(tester, de.findingCloseOfferDismiss);
    verifyNever(() => spots.update(any(), any()));
    expect(find.byType(VisitFlowScreen), findsNothing);
  });

  testWidgets('accepting the offer opens the ONE closing path', (tester) async {
    // The same sheet the dossier's phase control opens, not a second closing
    // route: it is what collects the reason the server requires, and a closing
    // without one is the state nobody can act on later.
    await pump(tester);
    await recordFinding(tester, de.findingKindSiteChange);
    await press(tester, de.visitFlowFinishAction);
    await press(tester, de.findingCloseOfferConfirm);

    expect(find.text(de.spotCloseFieldReason), findsOneWidget);
    await press(tester, de.spotMoveClose);
    // Refused in the form: a closing needs a reason.
    verifyNever(() => spots.update(any(), any()));

    await tester.tap(find.text(de.spotCloseFieldReason));
    await tester.pumpAndSettle();
    await tester.tap(find.text(de.closedReasonNetted).last);
    await tester.pumpAndSettle();
    await press(tester, de.spotMoveClose);

    final body =
        verify(() => spots.update('s1', captureAny())).captured.single
            as Map<String, dynamic>;
    expect(body['phase'], SpotPhase.closed.wire);
    expect(body['closed_reason'], ClosedReason.netted.wire);
  });

  testWidgets('a dead bird offers nothing', (tester) async {
    // Offering the closing on every Fund would make the offer meaningless, and
    // a dead pigeon is the most common entry in this work.
    await pump(tester);
    await recordFinding(tester, de.findingKindDeadBird);
    await press(tester, de.visitFlowFinishAction);

    expect(find.text(de.findingCloseOfferTitle), findsNothing);
    expect(find.byType(VisitFlowScreen), findsNothing);
  });

  testWidgets('a Spot that cannot be closed is not offered the move', (
    tester,
  ) async {
    // The transition graph is the server's. Offering a move it refuses is a
    // button whose only function is to produce an error message.
    when(() => spots.getOne(any())).thenAnswer(
      (_) async => const Spot(id: 's1', name: 'Zu', phase: SpotPhase.closed),
    );

    await pump(tester);
    await recordFinding(tester, de.findingKindSiteChange);
    await press(tester, de.visitFlowFinishAction);

    expect(find.text(de.findingCloseOfferTitle), findsNothing);
    expect(find.byType(VisitFlowScreen), findsNothing);
  });

  testWidgets('a Spot that cannot be READ costs the offer, not the visit', (
    tester,
  ) async {
    // The visit is already written by the time this runs. An error banner over
    // a successful visit would tell the volunteer their work failed.
    when(
      () => spots.getOne(any()),
    ).thenAnswer((_) async => throw const RepositoryException('nope'));

    await pump(tester);
    await recordFinding(tester, de.findingKindSiteChange);
    await press(tester, de.visitFlowFinishAction);

    expect(find.text(de.visitFlowSendFailedTitle), findsNothing);
    expect(find.byType(VisitFlowScreen), findsNothing);
  });

  group('the Bereich photo', () {
    /// Opens the nest through its LINE, not through the pin.
    ///
    /// With a photo on the screen the label exists twice — once as a pin, once
    /// as a line — so `find.text('N1')` is ambiguous and a test that used it
    /// would fail for a reason that has nothing to do with what it asserts.
    Future<void> openLine(WidgetTester tester, String label) async {
      await tester.tap(
        find.descendant(
          of: find.byType(VisitNestRow),
          matching: find.text(label),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the nests stand under their Bereich', (tester) async {
      // Grouped, and in the Bereiche's own order: that is the order somebody
      // physically walks the building in. A flat list of "N1, N2, L1" is a set
      // of labels that mean nothing to a person standing in a stairwell.
      when(() => areas.forSpot('s1')).thenAnswer(
        (_) async => [
          bereich,
          const Area(id: 'a2', name: 'Lichtschacht', spot: 's1'),
          // Nothing to check in it, so it is not drawn at all.
          const Area(id: 'a3', name: 'Keller', spot: 's1'),
        ],
      );
      when(() => nestStates.forSpot('s1')).thenAnswer(
        (_) async => [nestRow(), nestRow(id: 'n2', label: 'L1', area: 'a2')],
      );

      await pump(tester);

      final attic = find.ancestor(
        of: find.text('Dachboden Nord'),
        matching: find.byType(VisitAreaGroup),
      );
      expect(
        find.descendant(of: attic, matching: find.text('N1')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: attic, matching: find.text('L1')),
        findsNothing,
      );
      expect(find.text('Keller'), findsNothing);
    });

    testWidgets('the photo is the working surface: a pin opens THAT nest', (
      tester,
    ) async {
      // The point of having the picture here at all: you see the nest where it
      // sits and open it there, instead of matching "N1" to a rafter by hand.
      //
      // The pin is opened through the canvas' callback rather than by tapping
      // it, and not for convenience: the photo is a network image that never
      // resolves in a test, so the canvas has no height and the pin is laid out
      // outside its clip — a `tap` there silently lands on the nest LINE
      // underneath and the test passes without the pin taking part. (Measured:
      // it did.) The tap itself is covered on a canvas of a known size in
      // `pin_canvas_test.dart`; what can only be checked here is that a pin
      // maps back to the right nest.
      when(() => areas.forSpot('s1')).thenAnswer(
        (_) async => [bereichWithPhoto],
      );
      when(() => nestStates.forSpot('s1')).thenAnswer(
        (_) async => [
          nestRow(pinX: 0.5, pinY: 0.5),
          nestRow(id: 'n2', label: 'N2', pinX: 0.2, pinY: 0.2),
        ],
      );

      await pump(tester);
      await settle(tester);

      final canvas = tester.widget<PinCanvas>(find.byType(PinCanvas));
      // Interactive, unlike the dossier's read-only preview: here the pins are
      // the way into a nest, so they must not be wrapped away from the gesture.
      expect(canvas.onOpen, isNotNull);
      canvas.onOpen!(canvas.nests.firstWhere((pin) => pin.label == 'N2'));
      await settle(tester);

      expect(find.text(de.nestCheckTitle('N2')), findsOneWidget);
    });

    testWidgets('a recorded nest carries its state on the photo', (
      tester,
    ) async {
      // One nest must not say two things on one screen: a pin still saying
      // the species beside a line reading "getauscht" is the picture
      // disagreeing with the list under it.
      when(() => areas.forSpot('s1')).thenAnswer(
        (_) async => [bereichWithPhoto],
      );
      when(
        () => nestStates.forSpot('s1'),
      ).thenAnswer((_) async => [nestRow(pinX: 0.5, pinY: 0.5)]);

      await pump(tester);
      await settle(tester);
      final canvas = find.byType(PinCanvas);
      expect(
        find.descendant(
          of: canvas,
          matching: find.byIcon(nestSpeciesIcon(NestSpecies.feralPigeon)),
        ),
        findsOneWidget,
      );

      await openLine(tester, 'N1');
      await tester.tap(find.text(de.nestCheckSwapAllAction));
      await tester.pumpAndSettle();
      final apply = find.text(de.nestCheckApplyAction);
      await tester.ensureVisible(apply);
      await tester.pumpAndSettle();
      await tester.tap(apply);
      await settle(tester);

      expect(
        find.descendant(
          of: canvas,
          matching: find.byIcon(checkStateIcon(CheckState.swapped)),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: canvas,
          matching: find.byIcon(nestSpeciesIcon(NestSpecies.feralPigeon)),
        ),
        findsNothing,
      );
    });

    testWidgets('a missing photo can be taken WITHOUT leaving the visit', (
      tester,
    ) async {
      // The moment somebody notices the picture is missing is the moment they
      // are standing in the room. Sending them to the dossier for it means the
      // photo gets taken never.
      await pump(tester);

      await tester.tap(find.text(de.areaPhotoSetAction));
      await tester.pumpAndSettle();

      expect(find.text(de.photoCameraAction), findsOneWidget);
      expect(find.byType(VisitFlowScreen), findsOneWidget);
    });

    testWidgets('an existing photo is offered for REPLACEMENT', (tester) async {
      // Not removal: the pins sit on this picture, and dropping it would
      // strand them.
      when(() => areas.forSpot('s1')).thenAnswer(
        (_) async => [bereichWithPhoto],
      );

      await pump(tester);
      await settle(tester);

      expect(find.byTooltip(de.areaPhotoReplaceAction), findsOneWidget);
      expect(find.text(de.areaPhotoSetAction), findsNothing);
    });

    testWidgets('the raised review flag is STATED, and leads to the review', (
      tester,
    ) async {
      // A replacement taken during the visit puts the pins at the OLD photo's
      // positions. Standing in the room is the best moment to move them, so
      // the warning is the way in rather than a note to act on later.
      when(() => areas.forSpot('s1')).thenAnswer(
        (_) async => [bereichWithPhoto.copyWith(pinsNeedReview: true)],
      );
      when(() => nestStates.forSpot('s1')).thenAnswer((_) async => [nestRow()]);

      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            visitsRepositoryProvider.overrideWith((ref) async => visits),
            nestStateRepositoryProvider.overrideWith((ref) async => nestStates),
            nestEggsRepositoryProvider.overrideWith((ref) async => eggs),
            spotsRepositoryProvider.overrideWith((ref) async => spots),
            areasRepositoryProvider.overrideWith((ref) async => areas),
          ],
          child: MaterialApp.router(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('de'),
            // Two routes, not the app's: what is asserted is the DESTINATION,
            // and the pin editor's own dependencies are its own tests' problem.
            routerConfig: GoRouter(
              initialLocation: '/visit',
              routes: [
                GoRoute(
                  path: '/visit',
                  builder: (_, _) => const VisitFlowScreen(spotId: 's1'),
                ),
                GoRoute(
                  path: Routes.areaEditorPattern,
                  builder: (_, _) => const Text('pin review'),
                ),
              ],
            ),
          ),
        ),
      );
      await settle(tester);

      expect(find.text(de.areaPinsNeedReview), findsOneWidget);
      await tester.tap(find.text(de.areaPinsNeedReview));
      await settle(tester);

      expect(find.text('pin review'), findsOneWidget);
    });

    testWidgets('an unreadable Bereich list costs the photo, not the nests', (
      tester,
    ) async {
      // The nests are the work. A visit that could not be recorded because a
      // photo listing failed would be the worse outcome by a wide margin.
      when(
        () => areas.forSpot('s1'),
      ).thenAnswer((_) async => throw const RepositoryException('nope'));
      when(() => nestStates.forSpot('s1')).thenAnswer((_) async => [nestRow()]);

      await pump(tester);

      expect(find.text('N1'), findsOneWidget);
      expect(find.text(de.visitFlowProgress(0, 1)), findsOneWidget);
    });

    testWidgets('a phone-width Bereich header does not overflow', (
      tester,
    ) async {
      // The header carries a name of unknown length beside a control, on the
      // narrowest screen this app is used on — which is where this app is used.
      // An overflow here fails the test by itself.
      when(() => areas.forSpot('s1')).thenAnswer(
        (_) async => [
          bereich.copyWith(
            name: 'Dachboden Nord über dem Treppenhaus, hinterer Teil',
          ),
        ],
      );

      await pump(tester, surface: const Size(390, 844));

      expect(find.byType(VisitNestRow), findsOneWidget);
      expect(find.text(de.areaPhotoSetAction), findsOneWidget);
    });
  });
}
