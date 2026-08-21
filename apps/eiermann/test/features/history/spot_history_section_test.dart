import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/history/spot_history_section.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

import '../../support/harness.dart';

class _MockVisits extends Mock implements VisitHistoryRepository {}

class _MockChecks extends Mock implements NestChecksRepository {}

class _MockFindings extends Mock implements FindingsRepository {}

void main() {
  late AppLocalizations de;
  late _MockVisits visits;
  late _MockChecks checks;
  late _MockFindings findings;

  final when20 = DateTime.utc(2026, 8, 19, 9);

  setUpAll(() async {
    de = await germanStrings();
  });

  setUp(() {
    visits = _MockVisits();
    checks = _MockChecks();
    findings = _MockFindings();
    when(() => checks.forVisits(any())).thenAnswer((_) async => []);
    when(() => findings.forVisits(any())).thenAnswer((_) async => []);
  });

  void givenVisits(List<Visit> rows, {PbCursor? cursor}) => when(
    () => visits.pageForSpot(any(), after: any(named: 'after')),
  ).thenAnswer((_) async => PbPage(items: rows, cursor: cursor));

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpApp(
      const Scaffold(
        body: SingleChildScrollView(
          child: SpotHistorySection(spotId: 's1'),
        ),
      ),
      overrides: [
        visitHistoryRepositoryProvider.overrideWith((ref) async => visits),
        nestChecksRepositoryProvider.overrideWith((ref) async => checks),
        findingsRepositoryProvider.overrideWith((ref) async => findings),
      ],
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a building with no visits says the chronology starts later', (
    tester,
  ) async {
    givenVisits([]);

    await pump(tester);

    expect(find.text(de.spotHistoryEmpty), findsOneWidget);
  });

  testWidgets('one visit carries its checks AND its Funde — one list', (
    tester,
  ) async {
    // The whole design. A check and a Fund exist only because somebody was at
    // the building, so separating them into their own sections would make the
    // reader join three date-ordered lists by hand to answer "what happened on
    // the 19th".
    givenVisits([
      Visit(
        id: 'v1',
        spot: 's1',
        outcome: VisitOutcome.checked,
        visitedAt: when20,
        authorName: 'Kaya',
        note: 'Dachluke klemmt',
      ),
    ]);
    when(() => checks.forVisits(['v1'])).thenAnswer(
      (_) async => [
        NestCheck(
          id: 'c1',
          visit: 'v1',
          nest: 'n1',
          state: CheckState.swapped,
          realBefore: 2,
          removedReal: 2,
          addedDummy: 2,
          nestLabel: 'N1',
          checkedAt: when20,
        ),
        NestCheck(
          id: 'c2',
          visit: 'v1',
          nest: 'n2',
          state: CheckState.partial,
          realBefore: 2,
          removedReal: 1,
          addedDummy: 1,
          nestLabel: 'N2',
          checkedAt: when20,
        ),
      ],
    );
    when(() => findings.forVisits(['v1'])).thenAnswer(
      (_) async => [
        Finding(
          id: 'f1',
          spot: 's1',
          visit: 'v1',
          kind: FindingKind.deadBird,
          count: 1,
          speciesLabel: 'Dohle',
          foundAt: when20,
        ),
      ],
    );

    await pump(tester);

    // One card, and everything on it.
    expect(find.byType(Card), findsOneWidget);
    expect(find.textContaining('N1'), findsOneWidget);
    expect(find.textContaining('N2'), findsOneWidget);
    expect(find.textContaining('Dohle'), findsOneWidget);
    expect(find.text('Kaya'), findsOneWidget);
    expect(find.text('Dachluke klemmt'), findsOneWidget);
    // The summary counts the STORED checks, and the Halbgelege among them:
    // that flag is derived server-side from the arithmetic.
    expect(
      find.textContaining(de.visitFlowSummaryHalfClutch(1)),
      findsOneWidget,
    );
    expect(find.textContaining(de.visitFlowSummaryRemoved(3)), findsOneWidget);
  });

  testWidgets('a skipped visit reads as a fact, not as a failure', (
    tester,
  ) async {
    // Nobody there is a fact about the building. It gets its own icon and its
    // reason, and it does not get an egg summary it never produced.
    givenVisits([
      Visit(
        id: 'v1',
        spot: 's1',
        outcome: VisitOutcome.skipped,
        skipReason: SkipReason.noKey,
        skipNote: 'Kaya im Urlaub',
        visitedAt: when20,
      ),
    ]);

    await pump(tester);

    expect(find.textContaining(de.visitSkipTitle), findsOneWidget);
    expect(find.textContaining(de.skipReasonNoKey), findsOneWidget);
    expect(find.textContaining('Kaya im Urlaub'), findsOneWidget);
    expect(find.textContaining(de.visitFlowSummaryRemoved(0)), findsNothing);
  });

  testWidgets('three requests for a page, never three per visit', (
    tester,
  ) async {
    // A chronology that fetched per row is twenty requests for one screen,
    // which is what makes an app feel broken on a phone in a stairwell.
    givenVisits([
      for (var i = 0; i < 5; i++)
        Visit(id: 'v$i', spot: 's1', visitedAt: when20),
    ]);

    await pump(tester);

    verify(() => checks.forVisits(any())).called(1);
    verify(() => findings.forVisits(any())).called(1);
  });

  testWidgets('a check whose nest cannot be resolved names the gap', (
    tester,
  ) async {
    // Rather than printing an id nobody can act on.
    givenVisits([Visit(id: 'v1', spot: 's1', visitedAt: when20)]);
    when(() => checks.forVisits(any())).thenAnswer(
      (_) async => [
        NestCheck(
          id: 'c1',
          visit: 'v1',
          nest: 'gone',
          state: CheckState.empty,
          checkedAt: when20,
        ),
      ],
    );

    await pump(tester);

    expect(
      find.textContaining(de.spotHistoryUnknownNest),
      findsOneWidget,
    );
  });

  testWidgets('a failed read offers the retry rather than an empty history', (
    tester,
  ) async {
    // "No visits yet" about a building with a history is the worst possible
    // answer here: it reads as a record that was lost.
    when(
      () => visits.pageForSpot(any(), after: any(named: 'after')),
    ).thenAnswer((_) async => throw const RepositoryException('nope'));

    await pump(tester);

    expect(find.text(de.spotHistoryEmpty), findsNothing);
    expect(find.byType(ErrorView), findsOneWidget);
  });
}
