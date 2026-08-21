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

void main() {
  late AppLocalizations de;
  late _MockOverview repo;

  setUpAll(() async {
    de = await germanStrings();
  });

  setUp(() {
    repo = _MockOverview();
  });

  Future<void> pump(WidgetTester tester, List<SpotOverview> rows) async {
    when(() => repo.search(any())).thenAnswer((_) async => rows);
    await tester.pumpApp(
      const DashboardScreen(),
      overrides: [
        spotOverviewRepositoryProvider.overrideWith((ref) async => repo),
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
      expect(counts[SpotUrgency.dueThisWeek], isNull);
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
      // Neither of these earns a tile: they are the absence of work, and a
      // number for them would compete with the ranks that ask for a visit.
      overview(id: 's5', urgency: 3),
      overview(id: 's6', urgency: 6),
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
        of: tile(de.spotUrgencyDueThisWeek),
        matching: find.text('0'),
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
}
