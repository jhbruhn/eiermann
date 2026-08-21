import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/visits/nest_check_sheet.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/harness.dart';

class _MockEggs extends Mock implements NestEggsRepository {}

NestState nestRow({
  NestSpecies species = NestSpecies.feralPigeon,
  String? hint,
}) => NestState(
  id: 'n1',
  label: 'N3',
  area: 'a1',
  urgency: 3,
  spot: 's1',
  positionHint: hint,
  species: species,
);

NestEgg egg(int slot, EggKind kind, {int daysOld = 12}) => NestEgg(
  id: 'e$slot',
  nest: 'n1',
  kind: kind,
  slotIndex: slot,
  since: DateTime.now().subtract(Duration(days: daysOld)),
);

void main() {
  late AppLocalizations de;
  late _MockEggs eggs;

  setUpAll(() async => de = await germanStrings());

  setUp(() {
    eggs = _MockEggs();
    when(() => eggs.forNest(any())).thenAnswer((_) async => []);
  });

  /// Opens the sheet and hands back a getter for whatever it returned.
  Future<NestCheckDraft? Function()> open(
    WidgetTester tester, {
    required NestState nest,
    List<NestEgg> stored = const [],
  }) async {
    when(() => eggs.forNest('n1')).thenAnswer((_) async => stored);
    NestCheckDraft? result;
    var closed = false;

    await tester.pumpApp(
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showNestCheckSheet(context, nest: nest);
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
      overrides: [
        nestEggsRepositoryProvider.overrideWith((ref) async => eggs),
      ],
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () {
      expect(closed, isTrue, reason: 'the sheet never closed');
      return result;
    };
  }

  /// Presses "Übernehmen".
  ///
  /// Scrolled into view first: the sheet is a scroll view on a phone-sized test
  /// surface, and a tap at the centre of a button hanging below the fold hits
  /// whatever is drawn there instead — which reads as "the button did nothing".
  Future<void> pressApply(WidgetTester tester) async {
    final button = find.text(de.nestCheckApplyAction);
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Future<NestCheckDraft?> apply(
    WidgetTester tester,
    NestCheckDraft? Function() read,
  ) async {
    await pressApply(tester);
    return read();
  }

  testWidgets("the stored clutch is the starting point, with each egg's age", (
    tester,
  ) async {
    // Prefilled and correctable: a row nobody may edit would record last
    // month's clutch as today's reading, and birds lay eggs between visits.
    await open(
      tester,
      nest: nestRow(),
      stored: [egg(0, EggKind.dummy), egg(1, EggKind.real, daysOld: 2)],
    );

    expect(find.text(de.nestCheckAddDummy), findsWidgets);
    expect(find.text(de.nestAgeDays(12)), findsOneWidget);
    expect(find.text(de.nestAgeDays(2)), findsOneWidget);
  });

  testWidgets('applying without touching anything records what was found', (
    tester,
  ) async {
    // "Nichts angefasst" resets the ladder like any other find — the nest is in
    // use — and it must not be reachable by accident from an unloaded row.
    final read = await open(
      tester,
      nest: nestRow(),
      stored: [egg(0, EggKind.dummy), egg(1, EggKind.real)],
    );

    final draft = await apply(tester, read);

    expect(draft, isNotNull);
    expect(draft!.state, CheckState.untouched);
    expect(draft.realBefore, 1);
    expect(draft.dummyBefore, 1);
  });

  testWidgets('"alle tauschen" is one tap and leaves no real egg', (
    tester,
  ) async {
    final read = await open(
      tester,
      nest: nestRow(),
      stored: [egg(0, EggKind.real), egg(1, EggKind.real)],
    );

    await tester.tap(find.text(de.nestCheckSwapAllAction));
    await tester.pumpAndSettle();
    final draft = await apply(tester, read);

    expect(draft!.removedReal, 2);
    expect(draft.addedDummy, 2);
    expect(draft.effectiveState, CheckState.swapped);
  });

  testWidgets(
    'a real egg left behind warns about the Halbgelege, before saving',
    (tester) async {
      // Derived from the numbers rather than chosen, so nothing else on the
      // sheet would announce it — and it is the one thing somebody can still
      // correct while standing there.
      final read = await open(
        tester,
        nest: nestRow(),
        stored: [egg(0, EggKind.real), egg(1, EggKind.real)],
      );

      // One egg swapped, the other left: tap the first slot once.
      await tester.tap(find.text(de.nestCheckSlotKeep).first);
      await tester.pumpAndSettle();

      expect(find.text(de.nestCheckHalfClutchWarning), findsOneWidget);

      final draft = await apply(tester, read);
      expect(draft!.isHalfClutch, isTrue);
      expect(draft.realAfter, 1);
    },
  );

  testWidgets('an empty nest records empty — the state that moves the ladder', (
    tester,
  ) async {
    final read = await open(tester, nest: nestRow());

    final draft = await apply(tester, read);

    expect(draft!.state, CheckState.empty);
    expect(draft.realBefore, 0);
  });

  testWidgets('a protected nest gets an EXPLANATION, not a disabled button', (
    tester,
  ) async {
    // §44 BNatSchG is the one rule in this app that must stop somebody. A
    // greyed-out swap says "not for you"; what has to be said is "not at all,
    // and here is why".
    await open(tester, nest: nestRow(species: NestSpecies.protected));

    expect(find.text(de.nestCheckProtectedTitle), findsOneWidget);
    expect(find.textContaining('§44 BNatSchG'), findsOneWidget);
    // No egg row at all, so there is nothing to swap and nothing to grey out.
    expect(find.text(de.nestCheckSwapAllAction), findsNothing);
    expect(find.text(de.nestCheckAddReal), findsNothing);
  });

  testWidgets('a protected nest defaults to recording it as protected', (
    tester,
  ) async {
    // There is no clutch reading to fall back on, so one of the honest states
    // is always chosen — and reporting the bird IS the determination.
    final read = await open(
      tester,
      nest: nestRow(species: NestSpecies.protected),
    );

    final draft = await apply(tester, read);

    expect(draft!.state, CheckState.protected);
  });

  testWidgets('a special state overrides the clutch row', (tester) async {
    // Nobody saw the nest, so the numbers are not a reading of anything — and
    // the endpoint zeroes them.
    final read = await open(
      tester,
      nest: nestRow(),
      stored: [egg(0, EggKind.dummy)],
    );

    await tester.tap(find.text(de.checkStateNotReachable));
    await tester.pumpAndSettle();
    final draft = await apply(tester, read);

    expect(draft!.state, CheckState.notReachable);
    expect(draft.dummyBefore, 0);
  });

  testWidgets('a failed clutch read cannot become "the nest is empty"', (
    tester,
  ) async {
    // An empty row means `empty`, which is the one state that stretches the
    // ladder. A read that failed must be refused, not turned into a statement
    // about the nest.
    when(() => eggs.forNest('n1')).thenAnswer(
      (_) async => throw const RepositoryException('nope'),
    );
    NestCheckDraft? result;
    var closed = false;

    await tester.pumpApp(
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showNestCheckSheet(context, nest: nestRow());
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
      overrides: [
        nestEggsRepositoryProvider.overrideWith((ref) async => eggs),
      ],
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await pressApply(tester);

    expect(closed, isFalse, reason: 'the sheet must stay open');
    expect(result, isNull);
    expect(find.text(de.errorLoadFailed), findsWidgets);
  });
}
