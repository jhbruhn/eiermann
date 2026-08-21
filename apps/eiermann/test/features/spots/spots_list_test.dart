import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/spots/spots_list.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

import '../../support/harness.dart';

class _MockOverview extends Mock implements SpotOverviewRepository {}

SpotOverview overview({
  required String id,
  required String name,
  required int urgency,
  SpotPhase phase = SpotPhase.active,
  DateTime? nextDueAt,
  int contactCount = 0,
}) => SpotOverview(
  id: id,
  name: name,
  urgency: urgency,
  phase: phase,
  street: 'Bahnhofstraße 12',
  postalCode: '26122',
  city: 'Oldenburg',
  nextDueAt: nextDueAt,
  contactCount: contactCount,
);

void main() {
  late AppLocalizations de;
  late MaterialLocalizations materialDe;
  late _MockOverview repo;

  setUpAll(() async {
    de = await germanStrings();
    // The same formatter the row uses, so the assertion cannot silently pass
    // over a date rendered in the WRONG time zone: `formatLocalDate` converts,
    // and PocketBase stores UTC.
    materialDe = await GlobalMaterialLocalizations.delegate.load(
      const Locale('de'),
    );
  });

  setUp(() {
    repo = _MockOverview();
    when(
      () => repo.dueFirst(
        query: any(named: 'query'),
        urgency: any(named: 'urgency'),
        after: any(named: 'after'),
        perPage: any(named: 'perPage'),
      ),
    ).thenAnswer((_) async => const SpotOverviewPage(items: []));
  });

  Future<void> pump(WidgetTester tester, {SpotUrgency? urgency}) =>
      tester.pumpApp(
        Scaffold(body: SpotsList(urgency: urgency)),
        overrides: [
          spotOverviewRepositoryProvider.overrideWith((ref) async => repo),
        ],
      );

  void stubRows(List<SpotOverview> rows) {
    when(
      () => repo.dueFirst(
        query: any(named: 'query'),
        urgency: any(named: 'urgency'),
        after: any(named: 'after'),
        perPage: any(named: 'perPage'),
      ),
    ).thenAnswer((_) async => SpotOverviewPage(items: rows));
  }

  testWidgets('the loudest Spot is at the top, in the order the view gave', (
    tester,
  ) async {
    // The ordering is the SERVER's — one query, sorted by the view's urgency
    // rank. What this asserts is that the list does not reorder or group behind
    // its back, because a list that re-sorts on the device pages incorrectly:
    // the next page resumes from the last row the server sent, not the last one
    // drawn.
    stubRows([
      overview(
        id: 's1',
        name: 'Bahnhofstraße 12',
        urgency: 0,
        nextDueAt: DateTime.utc(2026, 8, 15),
      ),
      overview(id: 's2', name: 'Marktplatz 3', urgency: 2),
      overview(
        id: 's3',
        name: 'Lagerhalle Nord',
        urgency: 5,
        phase: SpotPhase.paused,
      ),
    ]);
    await pump(tester);
    await tester.pumpAndSettle();

    final first = tester.getTopLeft(find.text('Bahnhofstraße 12')).dy;
    final second = tester.getTopLeft(find.text('Marktplatz 3')).dy;
    final third = tester.getTopLeft(find.text('Lagerhalle Nord')).dy;
    expect(first, lessThan(second));
    expect(second, lessThan(third));
  });

  testWidgets('every row says IN WORDS why it is urgent, not just in colour', (
    tester,
  ) async {
    // Colour as the only carrier of meaning fails WCAG 1.4.1, and a red row
    // tells a colour-blind carer nothing at all. Each rank therefore has to be
    // readable with the colour removed.
    stubRows([
      overview(id: 's1', name: 'Rang null', urgency: 0),
      overview(id: 's2', name: 'Rang eins', urgency: 1),
      overview(id: 's3', name: 'Rang zwei', urgency: 2),
      overview(id: 's4', name: 'Rang drei', urgency: 3),
    ]);
    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining(de.spotUrgencyOverdue), findsOneWidget);
    expect(find.textContaining(de.spotUrgencyDueToday), findsOneWidget);
    expect(find.textContaining(de.spotUrgencyDueThisWeek), findsOneWidget);
    expect(find.textContaining(de.spotUrgencyInRhythm), findsOneWidget);
  });

  testWidgets('a rank this build cannot name says so instead of guessing', (
    tester,
  ) async {
    // The server gained a rank. Drawing it as "in Rhythmus" would state
    // something untrue about a building somebody has to visit.
    stubRows([overview(id: 's1', name: 'Ein Gebäude', urgency: 9)]);
    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining(de.spotUrgencyUnknown), findsOneWidget);
    expect(find.textContaining(de.spotUrgencyInRhythm), findsNothing);
  });

  testWidgets('a row carries the phase, the contact count and the due date', (
    tester,
  ) async {
    stubRows([
      overview(
        id: 's1',
        name: 'Bahnhofstraße 12',
        urgency: 0,
        nextDueAt: DateTime.utc(2026, 8, 15),
        contactCount: 2,
      ),
    ]);
    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.text('Bahnhofstraße 12, 26122 Oldenburg'), findsOneWidget);
    expect(find.text(de.spotPhaseActive), findsOneWidget);
    expect(find.text(de.spotContactCount(2)), findsOneWidget);
    // Rendered through formatLocalDate, so it is the reader's local calendar
    // day and not the UTC one — off by a day for anything stored after 22:00.
    expect(
      find.textContaining(
        formatLocalDate(materialDe, DateTime.utc(2026, 8, 15)),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a Spot with NO contacts says so — that is a handover gap', (
    tester,
  ) async {
    stubRows([overview(id: 's1', name: 'Kirchturm', urgency: 4)]);
    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.text(de.spotContactCount(0)), findsOneWidget);
  });

  testWidgets('an empty list offers the first Spot rather than a dead end', (
    tester,
  ) async {
    stubRows([]);
    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.text(de.spotsEmptyTitle), findsOneWidget);
    expect(find.text(de.spotsEmptyMessage), findsOneWidget);
    expect(find.text(de.spotsEmptyAction), findsOneWidget);
  });

  testWidgets('a failed load says so and offers a retry', (tester) async {
    when(
      () => repo.dueFirst(
        query: any(named: 'query'),
        urgency: any(named: 'urgency'),
        after: any(named: 'after'),
        perPage: any(named: 'perPage'),
      ),
    ).thenThrow(
      const RepositoryException('down', kind: RepositoryErrorKind.network),
    );
    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.text(de.errorLoadFailed), findsOneWidget);
    expect(find.text(de.actionRetry), findsOneWidget);
  });

  group('narrowed to one urgency rank', () {
    testWidgets('the rank goes to the SERVER, not to a pass over the page', (
      tester,
    ) async {
      // Filtering on the device would filter one page: the second page resumes
      // where the server left off, so a rank the client dropped afterwards
      // leaves the list with holes in it and a cursor that skips rows.
      stubRows([overview(id: 's1', name: 'Bahnhofstraße 12', urgency: 0)]);

      await pump(tester, urgency: SpotUrgency.overdue);
      await tester.pumpAndSettle();

      verify(
        () => repo.dueFirst(
          query: any(named: 'query'),
          urgency: SpotUrgency.overdue.rank,
          after: any(named: 'after'),
          perPage: any(named: 'perPage'),
        ),
      ).called(1);
    });

    testWidgets('a chip says which rank, so a short list cannot lie', (
      tester,
    ) async {
      // A reader who came from a dashboard tile and then searched would
      // otherwise read an empty result as "no such building", when it means
      // "no such building among the overdue ones".
      stubRows([overview(id: 's1', name: 'Bahnhofstraße 12', urgency: 0)]);

      await pump(tester, urgency: SpotUrgency.overdue);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(InputChip),
          matching: find.text(de.spotUrgencyOverdue),
        ),
        findsOneWidget,
      );
    });

    testWidgets('no chip at all when the list is showing everything', (
      tester,
    ) async {
      stubRows([overview(id: 's1', name: 'Bahnhofstraße 12', urgency: 0)]);

      await pump(tester);
      await tester.pumpAndSettle();

      expect(find.byType(InputChip), findsNothing);
    });

    testWidgets('an empty filtered list does NOT read as an empty org', (
      tester,
    ) async {
      // "Lege das erste Gebäude an" in front of a group with forty buildings is
      // worse than saying nothing: it tells them their data is gone.
      stubRows([]);

      await pump(tester, urgency: SpotUrgency.dueToday);
      await tester.pumpAndSettle();

      expect(find.text(de.spotsFilterEmpty), findsOneWidget);
      expect(find.text(de.spotsEmptyTitle), findsNothing);
      expect(find.text(de.spotsEmptyAction), findsNothing);
    });
  });
}
