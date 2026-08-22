import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/findings/findings_screen.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/harness.dart';

class _MockFindings extends Mock implements FindingsRepository {}

void main() {
  late AppLocalizations de;
  late _MockFindings findings;

  final when20 = DateTime.utc(2026, 8, 19, 9);

  setUpAll(() async {
    de = await germanStrings();
  });

  setUp(() {
    findings = _MockFindings();
  });

  void given(List<Finding> rows, {PbCursor? cursor}) => when(
    () => findings.pageRecent(after: any(named: 'after')),
  ).thenAnswer((_) async => PbPage(items: rows, cursor: cursor));

  Future<void> pump(WidgetTester tester) async {
    tester.useSurface(const Size(800, 1600));
    await tester.pumpApp(
      const FindingsScreen(),
      overrides: [
        findingsRepositoryProvider.overrideWith((ref) async => findings),
      ],
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the BUILDING leads each row', (tester) async {
    // The list spans buildings, so "Toter Vogel · Dohle" repeated eleven times
    // answers nothing: the question somebody brings here is where.
    given([
      Finding(
        id: 'f1',
        spot: 's1',
        kind: FindingKind.deadBird,
        count: 2,
        speciesLabel: 'Dohle',
        nestLabel: 'N1',
        spotName: 'Bahnhofstraße 12',
        authorName: 'Kaya',
        foundAt: when20,
      ),
    ]);

    await pump(tester);

    expect(find.text('Bahnhofstraße 12'), findsOneWidget);
    expect(find.textContaining('Dohle'), findsOneWidget);
    // The count leads only above one, and it is the stored one.
    expect(
      find.textContaining(
        de.findingCountPrefix(2, de.findingKindDeadBird),
      ),
      findsOneWidget,
    );
    expect(find.textContaining(de.findingAtNest('N1')), findsOneWidget);
  });

  testWidgets('a Fund whose building cannot be resolved names the gap', (
    tester,
  ) async {
    // Rather than printing an id: the building is what this list is read by.
    given([Finding(id: 'f1', spot: 'gone', foundAt: when20)]);

    await pump(tester);

    expect(find.text(de.findingsUnknownSpot), findsOneWidget);
  });

  testWidgets('nothing found says so, and says what would go here', (
    tester,
  ) async {
    given([]);

    await pump(tester);

    expect(find.text(de.findingsFeedEmptyTitle), findsOneWidget);
    expect(find.text(de.findingsFeedEmptyMessage), findsOneWidget);
  });

  testWidgets('a full page resumes from the LAST ROW, not from an offset', (
    tester,
  ) async {
    // KEYSET paging: this list grows at the end being read from, and `?page=2`
    // would shift the window under the reader — some rows twice, others never.
    // A short page WITH a cursor, so the tail is on screen and asks by itself.
    // `PagedListTail` requests on build for exactly this case: a list too short
    // to scroll would otherwise never load its second page.
    when(findings.pageRecent).thenAnswer(
      (_) async => PbPage(
        items: [
          for (var i = 0; i < 3; i++)
            Finding(
              id: 'f$i',
              spot: 's1',
              spotName: 'Haus $i',
              foundAt: when20,
            ),
        ],
        cursor: const PbCursor(value: '2026-08-19', id: 'f2'),
      ),
    );
    when(
      () => findings.pageRecent(
        after: any(named: 'after', that: isNotNull),
      ),
    ).thenAnswer((_) async => const PbPage(items: []));

    await pump(tester);

    final cursor = verify(
      () => findings.pageRecent(after: captureAny(named: 'after')),
    ).captured.whereType<PbCursor>().toList();
    expect(cursor.length, 1, reason: 'one page beyond the first');
    expect(cursor.single.id, 'f2', reason: 'resumed from the last row seen');
  });
}
