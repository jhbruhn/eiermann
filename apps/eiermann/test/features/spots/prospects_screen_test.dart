import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/spots/prospects_screen.dart';
import 'package:eiermann/features/spots/spot_labels.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

import '../../support/harness.dart';

class _MockOverview extends Mock implements SpotOverviewRepository {}

class _MockSpots extends Mock implements SpotsRepository {}

SpotOverview row({
  required String id,
  String name = 'Bahnhofstraße 12',
  SpotPhase phase = SpotPhase.prospect,
  ProspectStage? stage = ProspectStage.untouched,
  int contactCount = 1,
  DateTime? updated,
  int? urgency,
}) => SpotOverview(
  id: id,
  name: name,
  // What the view computes today: rank 4 for a prospect. Overridable, because
  // one test needs a row whose rank and phase DISAGREE — see there.
  urgency: urgency ?? (phase == SpotPhase.prospect ? 4 : 3),
  phase: phase,
  prospectStage: stage,
  contactCount: contactCount,
  updated: updated ?? DateTime.utc(2026, 8, 12),
);

void main() {
  late AppLocalizations de;
  late MaterialLocalizations materialDe;
  late _MockOverview overview;
  late _MockSpots spots;

  setUpAll(() async {
    de = await germanStrings();
    materialDe = await germanMaterialStrings();
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() {
    overview = _MockOverview();
    spots = _MockSpots();
  });

  Future<void> pump(WidgetTester tester, List<SpotOverview> rows) async {
    when(() => overview.search(any())).thenAnswer((_) async => rows);
    when(
      () => spots.update(any(), any()),
    ).thenAnswer((_) async => const Spot(id: 's1', name: 'Bahnhofstraße 12'));
    await tester.pumpApp(
      const ProspectsScreen(),
      overrides: [
        spotOverviewRepositoryProvider.overrideWith((ref) async => overview),
        spotsRepositoryProvider.overrideWith((ref) async => spots),
      ],
    );
    await tester.pumpAndSettle();
  }

  group('prospectsByStage', () {
    test('only Spots in the Erkundung phase', () {
      final groups = prospectsByStage([
        row(id: 's1'),
        row(id: 's2', phase: SpotPhase.active, stage: ProspectStage.permitted),
        row(
          id: 's3',
          phase: SpotPhase.paused,
          stage: ProspectStage.ownerSpoken,
        ),
      ]);

      expect(groups.keys, [ProspectStage.untouched]);
      expect(groups[ProspectStage.untouched]!.single.id, 's1');
    });

    test('the PHASE decides, not the display rank', () {
      // The two agree in today's view — a prospect ranks 4 — so this row is one
      // the server cannot currently produce, and that is the point: the rank is
      // a display order the view computes and may recompute, while the phase is
      // the fact about the building. A screen keyed on the rank would put a
      // paused Erkundung back into a funnel nobody is working.
      final groups = prospectsByStage([
        row(
          id: 'paused',
          phase: SpotPhase.paused,
          stage: ProspectStage.ownerSpoken,
          urgency: 4,
        ),
      ]);

      expect(groups, isEmpty);
    });

    test('a stage the wire could not name counts as untouched', () {
      // An Erkundung with no recorded step is exactly one nobody has taken. A
      // sixth group called "unbekannt" would be one nobody can act on.
      final groups = prospectsByStage([row(id: 's1', stage: null)]);

      expect(groups[ProspectStage.untouched]!.single.id, 's1');
    });

    test('the stalest sits at the top of its group', () {
      // Within one stage, the building nobody has touched for six weeks is
      // where it hangs.
      final groups = prospectsByStage([
        row(id: 'fresh', updated: DateTime.utc(2026, 8, 20)),
        row(id: 'stale', updated: DateTime.utc(2026, 6, 2)),
        row(id: 'middle', updated: DateTime.utc(2026, 7, 15)),
      ]);

      expect(groups[ProspectStage.untouched]!.map((r) => r.id), [
        'stale',
        'middle',
        'fresh',
      ]);
    });
  });

  testWidgets('the groups are the answer: stage, count, next step', (
    tester,
  ) async {
    await pump(tester, [
      row(id: 's1', name: 'Unberührt A'),
      row(id: 's2', name: 'Unberührt B'),
      row(
        id: 's3',
        name: 'Warten',
        stage: ProspectStage.ownerSpoken,
      ),
    ]);

    expect(
      find.text('${de.prospectStageUntouched} · 2'),
      findsOneWidget,
      reason: 'the count is the shape of the pipeline',
    );
    expect(find.text('${de.prospectStageOwnerSpoken} · 1'), findsOneWidget);
    // The next action is per GROUP: the same sentence for every building
    // waiting on the same thing.
    expect(find.text(de.prospectsNextUntouched), findsOneWidget);
    expect(find.text(de.prospectsNextOwnerSpoken), findsOneWidget);
    // An empty stage is left out rather than drawn as a zero.
    expect(find.textContaining(de.prospectStageRefused), findsNothing);
  });

  testWidgets('a building nobody can be rung about is called out', (
    tester,
  ) async {
    // It is not waiting on a reply — it is waiting on somebody to find out who
    // to ask, which is a different job.
    await pump(tester, [
      row(id: 's1', name: 'Ohne Kontakt', contactCount: 0),
      row(id: 's2', name: 'Mit Kontakt', contactCount: 2),
    ]);

    expect(find.text(de.prospectsNoContact), findsOneWidget);
    expect(find.text(de.spotContactCount(2)), findsOneWidget);
  });

  testWidgets("the date is the record's, and says so", (tester) async {
    // `updated` is the last change to the row, not the date of a conversation.
    // Labelling it "seit dem Gespräch" would date something nobody recorded.
    await pump(tester, [row(id: 's1', updated: DateTime.utc(2026, 7, 4))]);

    // Through formatLocalDate, so it is the reader's local calendar day and
    // not the UTC one — off by a day for anything stored after 22:00 CET.
    expect(
      find.text(
        de.prospectsLastChanged(
          formatLocalDate(materialDe, DateTime.utc(2026, 7, 4)),
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('recording a step writes ONE field', (tester) async {
    // A form body would clear the address of a building somebody just typed
    // one for. See SpotsRepository.stageBody.
    await pump(tester, [row(id: 's1', stage: ProspectStage.tenantSpoken)]);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text(de.prospectStageOwnerSpoken).last);
    await tester.pumpAndSettle();

    verify(
      () => spots.update('s1', {'prospect_stage': 'owner_spoken'}),
    ).called(1);
  });

  testWidgets('the menu offers every OTHER stage, and no invented order', (
    tester,
  ) async {
    // The server has no ordering rule for stages, so a client that offered
    // only "the next one" would enforce a rule nothing else knows — and it
    // could not record that the tenant turned out to be the owner.
    await pump(tester, [row(id: 's1', stage: ProspectStage.tenantSpoken)]);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    for (final stage in ProspectStage.values) {
      final label = prospectStageLabel(de, stage);
      expect(
        find.descendant(
          of: find.byType(PopupMenuItem<ProspectStage>),
          matching: find.text(label),
        ),
        stage == ProspectStage.tenantSpoken ? findsNothing : findsOneWidget,
        reason: label,
      );
    }
  });

  testWidgets('a failed write says so — nothing else on screen would', (
    tester,
  ) async {
    await pump(tester, [row(id: 's1')]);
    // Stubbed AFTER the pump: `pump` registers the happy path, and a throw set
    // up before it would be overwritten by that registration.
    when(
      () => spots.update(any(), any()),
    ).thenThrow(const RepositoryException('offline'));

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text(de.prospectStageOwnerSpoken).last);
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('no Erkundung is a starting point, not an empty list', (
    tester,
  ) async {
    await pump(tester, [
      row(id: 's1', phase: SpotPhase.active, stage: ProspectStage.permitted),
    ]);

    expect(find.text(de.prospectsEmptyTitle), findsOneWidget);
    expect(find.text(de.spotsEmptyAction), findsWidgets);
  });

  testWidgets('the funnel costs no query of its own', (tester) async {
    // It reads the same unpaged view the map and the dashboard read. Two reads
    // could show two different numbers for one pipeline.
    await pump(tester, [row(id: 's1')]);

    verify(() => overview.search('')).called(1);
    verifyNoMoreInteractions(overview);
  });
}
