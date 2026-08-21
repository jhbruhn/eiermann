import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/nests/nest_list.dart';
import 'package:eiermann/features/nests/nest_sheet.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/harness.dart';

class _MockNests extends Mock implements NestsRepository {}

NestState row({
  required String id,
  String label = 'N1',
  int urgency = 3,
  int real = 0,
  int dummy = 0,
  String? hint,
  NestSpecies species = NestSpecies.feralPigeon,
  String? speciesLabel,
  NestStatus status = NestStatus.active,
  DateTime? oldestSince,
  DateTime? lastCheckedAt,
}) => NestState(
  id: id,
  label: label,
  area: 'a1',
  urgency: urgency,
  spot: 's1',
  positionHint: hint,
  species: species,
  speciesLabel: speciesLabel,
  status: status,
  realCount: real,
  dummyCount: dummy,
  oldestSince: oldestSince,
  lastCheckedAt: lastCheckedAt,
);

void main() {
  late AppLocalizations de;
  late _MockNests nests;

  setUpAll(() async {
    de = await germanStrings();
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() {
    nests = _MockNests();
    when(() => nests.forArea(any())).thenAnswer((_) async => []);
  });

  Future<void> pump(WidgetTester tester, List<NestState> rows) async {
    await tester.pumpApp(
      Scaffold(
        body: NestList(nests: rows, areaId: 'a1'),
      ),
      overrides: [
        nestsRepositoryProvider.overrideWith((ref) async => nests),
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

  testWidgets('a Bereich with no nests names the gesture that makes one', (
    tester,
  ) async {
    // Tapping a photo to create something is not discoverable, and this is the
    // only place that can say so.
    await pump(tester, []);

    expect(find.text(de.nestsEmptyInArea), findsOneWidget);
  });

  testWidgets('a nest can be added WITHOUT a pin, from the list', (
    tester,
  ) async {
    // The only route on a Bereich that has no photo yet — and the way to record
    // a nest whose position nobody can point at. Without it, a photo-less
    // Bereich is a dead end: the list says "tap the photo" beside a box that
    // says "no photo".
    await pump(tester, []);

    await tester.tap(find.text(de.nestsAddAction));
    await tester.pumpAndSettle();

    expect(find.byType(NestSheet), findsOneWidget);
    expect(find.text(de.nestSheetTitleNew), findsOneWidget);
  });

  testWidgets('the suggested label skips the ones already on the Bereich', (
    tester,
  ) async {
    await pump(tester, [row(id: 'n1'), row(id: 'n2', label: 'N2')]);

    await tester.tap(find.text(de.nestsAddAction));
    await tester.pumpAndSettle();

    // On the visible text, not on the field's initialValue: what matters is
    // what the volunteer reads in the box before typing over it.
    // On the visible text, not on the field's initialValue: what matters is
    // what the volunteer reads in the box before typing over it. Two matches,
    // because a TextField draws its value and its own editing overlay.
    expect(
      find.descendant(of: find.byType(NestSheet), matching: find.text('N3')),
      findsWidgets,
    );
  });

  testWidgets('the way in is there even with nests already listed', (
    tester,
  ) async {
    await pump(tester, [row(id: 'n1')]);

    expect(find.text(de.nestsAddAction), findsOneWidget);
  });

  testWidgets('the Ist-Gelege is spelled out, dummies first', (tester) async {
    // Dummies lead because that is the number somebody packs the car by — the
    // concept calls it the smallest feature with the highest everyday value.
    await pump(tester, [row(id: 'n1', real: 1, dummy: 2)]);

    expect(
      find.text('${de.nestContentDummy(2)} · ${de.nestContentReal(1)}'),
      findsOneWidget,
    );
  });

  testWidgets('an empty nest says "leer" rather than nothing at all', (
    tester,
  ) async {
    await pump(tester, [row(id: 'n1')]);

    expect(find.text(de.nestContentEmpty), findsOneWidget);
  });

  testWidgets('the age is measured from the oldest egg', (tester) async {
    final since = DateTime.now().toUtc().subtract(const Duration(days: 12));
    await pump(tester, [row(id: 'n1', dummy: 1, oldestSince: since)]);

    expect(find.text(de.nestAgeDays(12)), findsOneWidget);
  });

  testWidgets('a nest nobody has visited says so, not "0 Tage"', (
    tester,
  ) async {
    // "0 Tage" would read as "checked today", which is the opposite of the
    // truth for a nest that was drawn on the photo and never looked at.
    await pump(tester, [row(id: 'n1')]);

    expect(find.text(de.nestNeverChecked), findsOneWidget);
    expect(find.text(de.nestAgeDays(0)), findsNothing);
  });

  testWidgets('a protected nest reads "nicht anfassen", with its species', (
    tester,
  ) async {
    // There is no egg work to report there, so the clutch reading is REPLACED
    // rather than shown alongside — §44 BNatSchG, and the words are the point.
    await pump(tester, [
      row(
        id: 'n1',
        urgency: 4,
        species: NestSpecies.protected,
        speciesLabel: 'Dohle',
        // Even with eggs in it: what is in a jackdaw's nest is not a clutch
        // anybody may act on.
        real: 2,
      ),
    ]);

    expect(
      find.text('Dohle — ${de.nestProtectedDoNotTouch}'),
      findsOneWidget,
    );
    expect(find.text(de.nestContentReal(2)), findsNothing);
  });

  testWidgets("the order is the SERVER's, never re-sorted here", (
    tester,
  ) async {
    // The rank is a column of the view. A list that re-ordered on the device
    // would disagree with the one the coordination is looking at.
    await pump(tester, [
      row(id: 'n3', label: 'N3', urgency: 0),
      row(id: 'n1'),
      row(id: 'n4', label: 'N4', urgency: 4, species: NestSpecies.protected),
    ]);

    final first = tester.getTopLeft(find.text('N3')).dy;
    final second = tester.getTopLeft(find.text('N1')).dy;
    final third = tester.getTopLeft(find.text('N4')).dy;
    expect(first, lessThan(second));
    expect(second, lessThan(third));
  });

  testWidgets('the position hint is on the line — a pin cannot say it', (
    tester,
  ) async {
    await pump(tester, [row(id: 'n1', hint: 'Balken links')]);

    expect(find.text('Balken links'), findsOneWidget);
  });

  testWidgets('tapping a line opens that nest, without a second request', (
    tester,
  ) async {
    // Everything the sheet edits is already on the row the view returned.
    await pump(tester, [row(id: 'n1', label: 'N7', hint: 'Balken links')]);

    await tester.tap(find.text('N7'));
    await tester.pumpAndSettle();

    expect(find.byType(NestSheet), findsOneWidget);
    expect(find.text(de.nestSheetTitleEdit), findsOneWidget);
    verifyNever(() => nests.getOne(any()));
  });
}
