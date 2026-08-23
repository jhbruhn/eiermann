import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/dashboard/dashboard_screen.dart';
import 'package:eiermann/features/spots/spots_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

import '../../support/harness.dart';

class _MockOverview extends Mock implements SpotOverviewRepository {}

class _MockFollowUps extends Mock implements FollowUpsRepository {}

class _MockTourRuns extends Mock implements TourRunsRepository {}

class _MockFindings extends Mock implements FindingsRepository {}

SpotOverview overview({
  required String id,
  required int urgency,
  String name = 'Bahnhofstraße 12',
}) => SpotOverview(
  id: id,
  name: name,
  urgency: urgency,
  phase: SpotPhase.active,
);

/// One open Nachkontrolle, with the labels the expand carries.
FollowUp followUp({
  String id = 'f1',
  String spot = 's1',
  String? spotName = 'Bahnhofstr. 12',
  String? nestLabel = 'N3',
  DateTime? dueAt,
  FollowUpReason reason = FollowUpReason.halfClutch,
}) => FollowUp(
  id: id,
  spot: spot,
  nest: 'n3',
  spotName: spotName,
  nestLabel: nestLabel,
  dueAt: dueAt ?? DateTime.now().add(const Duration(days: 3)),
  reason: reason,
);

void main() {
  late AppLocalizations de;
  late _MockOverview repo;
  late _MockFollowUps followUps;
  late _MockTourRuns runs;
  late _MockFindings findings;

  setUpAll(() async {
    de = await germanStrings();
  });

  setUp(() {
    repo = _MockOverview();
    followUps = _MockFollowUps();
    runs = _MockTourRuns();
    findings = _MockFindings();
    when(followUps.open).thenAnswer((_) async => []);
    when(() => runs.openFor(any())).thenAnswer((_) async => null);
    when(() => findings.countSince(any())).thenAnswer((_) async => 0);
  });

  Future<void> pump(
    WidgetTester tester,
    List<SpotOverview> rows, {
    List<FollowUp> open = const [],
    TourRun? openRun,
    int? recentFindings = 0,
  }) async {
    when(() => repo.search(any())).thenAnswer((_) async => rows);
    when(followUps.open).thenAnswer((_) async => open);
    when(() => runs.openFor(any())).thenAnswer((_) async => openRun);
    when(() => findings.countSince(any())).thenAnswer(
      (_) async => recentFindings ?? (throw const RepositoryException('nope')),
    );
    await tester.pumpApp(
      const DashboardScreen(),
      overrides: [
        spotOverviewRepositoryProvider.overrideWith((ref) async => repo),
        followUpsRepositoryProvider.overrideWith((ref) async => followUps),
        tourRunsRepositoryProvider.overrideWith((ref) async => runs),
        findingsRepositoryProvider.overrideWith((ref) async => findings),
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
    await tester.pumpAndSettle();
  }

  /// The tile for [label], so an assertion cannot accidentally read the number
  /// out of a neighbouring tile.
  Finder tile(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byType(KpiCard),
  );

  group('countByUrgency', () {
    test('counts each rank separately', () {
      final counts = countByUrgency([
        overview(id: 's1', urgency: 0),
        overview(id: 's2', urgency: 0),
        overview(id: 's3', urgency: 1),
      ]);

      expect(counts[SpotUrgency.overdue], 2);
      expect(counts[SpotUrgency.dueToday], 1);
      expect(counts[SpotUrgency.dueSoon], isNull);
    });

    test('a rank this build cannot name is left out, not folded in', () {
      // The server gained a rank. Counting it as the nearest one this build
      // knows would state something untrue about how much work is waiting.
      final counts = countByUrgency([
        overview(id: 's1', urgency: 0),
        overview(id: 's2', urgency: 9),
      ]);

      expect(counts[SpotUrgency.overdue], 1);
      expect(counts.values.fold(0, (a, b) => a + b), 1);
    });
  });

  testWidgets('the numbers are per rank, and each rank keeps its own tile', (
    tester,
  ) async {
    await pump(tester, [
      overview(id: 's1', urgency: 0),
      overview(id: 's2', urgency: 0),
      overview(id: 's3', urgency: 1),
      overview(id: 's4', urgency: 4),
      overview(id: 's5', urgency: 5),
      // Neither of these earns a tile: they are the absence of work, and a
      // number for them would compete with the ranks that ask for a visit.
      overview(id: 's6', urgency: 3),
      overview(id: 's7', urgency: 7),
    ]);

    expect(
      find.descendant(
        of: tile(de.spotUrgencyOverdue),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: tile(de.spotUrgencyDueToday),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: tile(de.spotUrgencyDueSoon),
        matching: find.text('0'),
      ),
      findsOneWidget,
    );
    // Rank 4, the rung `needsSurvey` took when it stopped borrowing a due
    // rank (eiermann-m0r). It gets a tile because it is work, and it is
    // counted apart from the three visit tiles because it is another kind.
    expect(
      find.descendant(
        of: tile(de.spotUrgencyNeedsSurvey),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: tile(de.spotUrgencyProspect),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    expect(find.text(de.spotUrgencyInRhythm), findsNothing);
    expect(find.text(de.spotUrgencyClosed), findsNothing);
  });

  testWidgets('a tile at zero is not a way in', (tester) async {
    // A number that promises a destination and delivers an empty list is worse
    // than a number that plainly reports nothing to do. The chevron is what
    // KpiCard draws for a tile with somewhere to go.
    await pump(tester, [overview(id: 's1', urgency: 0)]);

    expect(
      find.descendant(
        of: tile(de.spotUrgencyOverdue),
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: tile(de.spotUrgencyDueToday),
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsNothing,
    );
  });

  testWidgets('an org with no Spots reads as a starting point', (tester) async {
    // Not four zeros: nothing has been set up yet, and the only useful thing on
    // this screen is the way to start.
    await pump(tester, []);

    expect(find.text(de.spotsEmptyTitle), findsOneWidget);
    expect(find.text(de.spotsEmptyAction), findsOneWidget);
    expect(find.byType(KpiCard), findsNothing);
  });

  testWidgets('the counts cost no query of their own', (tester) async {
    // One read of `spot_overview` for the whole screen, and it is the same read
    // the map draws its pins from — so opening one after the other costs
    // nothing.
    await pump(tester, [overview(id: 's1', urgency: 0)]);

    verify(() => repo.search('')).called(1);
  });

  group('the Halbgelege block', () {
    testWidgets('sits ABOVE the counts, because days beat weeks', (
      tester,
    ) async {
      // The concept's ordering, not a layout preference: out of a half clutch a
      // chick hatches in days, and a number counting them among the others
      // would put a four-day window next to a four-week one.
      await pump(
        tester,
        [overview(id: 's1', urgency: 0)],
        open: [followUp()],
      );

      final title = tester.getTopLeft(find.text(de.dashboardHalfClutchTitle));
      final counts = tester.getTopLeft(find.byType(KpiCard).first);
      expect(title.dy, lessThan(counts.dy));
    });

    testWidgets('names the building and the nest, never an id', (tester) async {
      // An id with no label next to it is a bug in this app — and "which nest
      // in which building" is the decision this block exists for.
      await pump(tester, [overview(id: 's1', urgency: 3)], open: [followUp()]);

      expect(
        find.text('Bahnhofstr. 12 · ${de.dashboardFollowUpNest('N3')}'),
        findsOneWidget,
      );
    });

    testWidgets('an overdue return says overdue, not just its date', (
      tester,
    ) async {
      await pump(
        tester,
        [overview(id: 's1', urgency: 0)],
        open: [
          followUp(dueAt: DateTime.now().subtract(const Duration(days: 2))),
        ],
      );

      // The words AND the shape: colour alone says nothing to a colour-blind
      // reader, and this is the loudest row on the screen.
      expect(
        find.textContaining(de.dashboardFollowUpOverdue('').trim()),
        findsOneWidget,
      );
      // Scoped to the row: the overdue COUNT tile carries the same icon, which
      // is the point — one visual language for "late" on the whole screen.
      expect(
        find.descendant(
          of: find.byType(ListTile),
          matching: find.byIcon(Icons.priority_high),
        ),
        findsOneWidget,
      );
    });

    testWidgets('nothing open is said out loud', (tester) async {
      // An absent block would read as "not loaded" on the screen whose whole
      // job is telling you what is waiting.
      await pump(tester, [overview(id: 's1', urgency: 3)]);

      expect(find.text(de.dashboardHalfClutchEmpty), findsOneWidget);
    });

    testWidgets('a failed read hides the block instead of taking the screen', (
      tester,
    ) async {
      // It sits above the counts, so an error banner here would push the whole
      // dashboard off the screen. The counts below carry their own error state.
      when(followUps.open).thenAnswer(
        (_) async => throw const RepositoryException('nope'),
      );
      when(() => repo.search(any())).thenAnswer(
        (_) async => [overview(id: 's1', urgency: 0)],
      );
      await tester.pumpApp(
        const DashboardScreen(),
        overrides: [
          spotOverviewRepositoryProvider.overrideWith((ref) async => repo),
          followUpsRepositoryProvider.overrideWith((ref) async => followUps),
        ],
      );
      await tester.pumpAndSettle();

      expect(find.text(de.dashboardHalfClutchTitle), findsNothing);
      expect(find.byType(KpiCard), findsWidgets);
    });
  });
  testWidgets('an open round is offered above everything else', (tester) async {
    // Above even the Halbgelege, and that is a ranking of INTERRUPTION rather
    // than of importance: somebody who left a round half-walked and reopened
    // the app is in the middle of something, and the first thing they need is
    // the way back into it.
    await pump(
      tester,
      [overview(id: 's1', urgency: SpotUrgency.overdue.rank)],
      open: [followUp()],
      openRun: TourRun(
        id: 'r1',
        tour: 't1',
        tourName: 'Tour 1',
        startedBy: 'u1',
        startedAt: DateTime.utc(2026, 8, 21, 7),
      ),
    );

    expect(find.text(de.tourRunResume('Tour 1')), findsOneWidget);
    final resume = tester.getTopLeft(find.text(de.tourRunResume('Tour 1')));
    final halfClutch = tester.getTopLeft(
      find.text(de.dashboardHalfClutchTitle),
    );
    expect(resume.dy, lessThan(halfClutch.dy));
  });

  testWidgets('no open round means no card, not an empty one', (tester) async {
    await pump(tester, [overview(id: 's1', urgency: SpotUrgency.overdue.rank)]);

    expect(find.textContaining('fortsetzen'), findsNothing);
  });

  group('the Funde number', () {
    testWidgets('counts a WINDOW, and is a way in', (tester) async {
      // An all-time total only grows, so it stops carrying information after
      // the first season. And a number on this screen has to be openable: "7
      // Funde" that leads nowhere is a fact nobody can act on.
      await pump(
        tester,
        [overview(id: 's1', urgency: SpotUrgency.overdue.rank)],
        recentFindings: 7,
      );

      final card = tile(de.dashboardFindingsLabel);
      expect(card, findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('7')), findsOne);
      expect(tester.widget<KpiCard>(card).onTap, isNotNull);
    });

    testWidgets('zero keeps its tile and loses its tap', (tester) async {
      // Zero is a real reading, and the tile stays so the grid does not reflow.
      // A promised destination that turns out to be an empty list is worse than
      // a number plainly reporting nothing.
      await pump(tester, [overview(id: 's1', urgency: 0)]);

      final card = tile(de.dashboardFindingsLabel);
      expect(find.descendant(of: card, matching: find.text('0')), findsOne);
      expect(tester.widget<KpiCard>(card).onTap, isNull);
    });

    testWidgets('a failed read draws a dash, not an error over the grid', (
      tester,
    ) async {
      // This tile comes from a DIFFERENT request than the four beside it, and
      // one server hiccup must not make the whole dashboard look broken.
      await pump(tester, [
        overview(id: 's1', urgency: 0),
      ], recentFindings: null);

      final card = tile(de.dashboardFindingsLabel);
      expect(find.descendant(of: card, matching: find.text('—')), findsOne);
      expect(tester.widget<KpiCard>(card).onTap, isNull);
      // The rank tiles still read their own numbers.
      expect(tile(de.spotUrgencyOverdue), findsOneWidget);
    });
  });
}
