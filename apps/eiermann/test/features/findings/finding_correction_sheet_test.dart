import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/findings/finding_correction_sheet.dart';
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

  setUpAll(() async {
    de = await germanStrings();
  });

  setUp(() {
    findings = _MockFindings();
    when(
      () => findings.correct(
        any(),
        count: any(named: 'count'),
        note: any(named: 'note'),
        speciesLabel: any(named: 'speciesLabel'),
      ),
    ).thenAnswer(
      (_) async =>
          const Finding(id: 'f1', spot: 's1', kind: FindingKind.deadBird),
    );
  });

  final deadBird = Finding(
    id: 'f1',
    spot: 's1',
    kind: FindingKind.deadBird,
    count: 2,
    speciesLabel: 'Ringeltaube',
    note: 'unter dem Fenster',
    nestLabel: 'N3',
    authorName: 'Ada',
    foundAt: DateTime.utc(2026, 8, 19, 9),
  );

  Future<void> pump(WidgetTester tester, Finding finding) async {
    // A tall surface: a ListView does not build what is below the fold, and on
    // the default 800x600 the save button reads as missing the moment anything
    // is inserted above it.
    tester.useSurface(const Size(800, 1600));
    await tester.pumpApp(
      // Inside a Scaffold, like every other sheet test: a bare TextField has no
      // Material ancestor and asserts before anything can be looked at.
      Scaffold(body: FindingCorrectionSheet(finding: finding)),
      overrides: [
        findingsRepositoryProvider.overrideWith((ref) async => findings),
      ],
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the event is shown, and none of it is a control', (
    tester,
  ) async {
    // The kind, the nest, the date and the author are what this Fund WAS. They
    // are on screen so nobody corrects the wrong row, and none of them is
    // offered for editing — the collection's update rule pins every one, and a
    // body carrying one is refused outright rather than partly applied.
    await pump(tester, deadBird);

    expect(find.textContaining(de.findingKindDeadBird), findsOneWidget);
    expect(find.textContaining('N3'), findsOneWidget);
    expect(find.text(de.findingCorrectEventFixed), findsOneWidget);

    // The kind chips are the draft sheet's control, and their absence here is
    // the whole difference between the two sheets.
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text(de.findingKindQuestion), findsNothing);
    // Likewise the nest picker: re-pointing a Fund at another nest would be
    // rewriting the event, not correcting the description.
    expect(find.text(de.findingNestLabel), findsNothing);
  });

  testWidgets('it opens on what was recorded', (tester) async {
    // A correction form that started empty would make "fix the species" mean
    // "retype everything", and the note is the field people have written most
    // in.
    await pump(tester, deadBird);

    expect(find.text('Ringeltaube'), findsOneWidget);
    expect(find.text('unter dem Fenster'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('saving sends the three fields it edited', (tester) async {
    await pump(tester, deadBird);

    await tester.enterText(find.text('Ringeltaube'), 'Dohle');
    await tester.pumpAndSettle();
    await tester.tap(find.text(de.findingCorrectSaveAction));
    await tester.pumpAndSettle();

    verify(
      () => findings.correct(
        'f1',
        count: 2,
        note: 'unter dem Fenster',
        speciesLabel: 'Dohle',
      ),
    ).called(1);
  });

  testWidgets('a species name can be CLEARED, not only replaced', (
    tester,
  ) async {
    // The reason `correct` takes nulls and the body writes empty strings: a
    // PATCH that omitted the key would keep the stored value, and "there was no
    // species, I guessed" would be uncorrectable.
    await pump(tester, deadBird);

    await tester.enterText(find.text('Ringeltaube'), '');
    await tester.pumpAndSettle();
    await tester.tap(find.text(de.findingCorrectSaveAction));
    await tester.pumpAndSettle();

    verify(
      () => findings.correct(
        'f1',
        count: 2,
        note: 'unter dem Fenster',
        // The null IS the assertion, so it is spelled out. Left off, `verify`
        // would still match on the default and say nothing about what this
        // test is for.
        // ignore: avoid_redundant_argument_values
        speciesLabel: null,
      ),
    ).called(1);
  });

  testWidgets('a structural change is not asked for a species', (
    tester,
  ) async {
    // Netting has no species, and an empty field under it invites somebody to
    // type the building material. Same rule the draft sheet applies.
    await pump(
      tester,
      const Finding(id: 'f2', spot: 's1', kind: FindingKind.siteChange),
    );

    expect(find.text(de.findingSpeciesLabel), findsNothing);
  });

  testWidgets('...unless one was recorded, which is then clearable', (
    tester,
  ) async {
    // A Fund recorded before that rule existed can still carry a species. The
    // field appears exactly so there is a way to take it back out; hiding it
    // would make the wrong value permanent.
    await pump(
      tester,
      const Finding(
        id: 'f3',
        spot: 's1',
        kind: FindingKind.siteChange,
        speciesLabel: 'Ringeltaube',
      ),
    );

    expect(find.text('Ringeltaube'), findsOneWidget);
  });
}
