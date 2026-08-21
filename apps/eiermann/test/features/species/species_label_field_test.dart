import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/species/species_label_field.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/harness.dart';

class _MockLabels extends Mock implements SpeciesLabelsRepository {}

SpeciesLabel row(String label, {int used = 1}) =>
    SpeciesLabel(id: 'org:$label', label: label, usedCount: used);

void main() {
  late AppLocalizations de;
  late _MockLabels labels;
  late TextEditingController controller;

  setUpAll(() async {
    de = await germanStrings();
  });

  setUp(() {
    labels = _MockLabels();
    controller = TextEditingController();
    when(() => labels.all()).thenAnswer(
      (_) async => [
        row('Dohle', used: 7),
        row('Turmfalke', used: 3),
        row('Mauersegler'),
      ],
    );
  });

  tearDown(() => controller.dispose());

  Future<void> pump(WidgetTester tester, {VoidCallback? onPicked}) async {
    await tester.pumpApp(
      Scaffold(
        body: SpeciesLabelField(
          controller: controller,
          label: 'Welche Art?',
          onPicked: onPicked,
        ),
      ),
      overrides: [
        speciesLabelsRepositoryProvider.overrideWith((ref) async => labels),
      ],
    );
    await tester.pumpAndSettle();
  }

  testWidgets('offers what this group has already recorded', (tester) async {
    await pump(tester);

    expect(find.widgetWithText(ActionChip, 'Dohle'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Turmfalke'), findsOneWidget);
    // The price of a vocabulary that grows from use, stated under the field.
    expect(find.text(de.speciesLabelHint), findsOneWidget);
  });

  testWidgets('typing narrows the suggestions', (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextFormField), 'falk');
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ActionChip, 'Turmfalke'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Dohle'), findsNothing);
  });

  testWidgets('a word nobody has used before is still accepted', (
    tester,
  ) async {
    // The whole point: the app does not identify species, it asks. A field that
    // only took known words would be a curated list with extra steps — and the
    // one bird somebody is looking at is the one that is missing.
    await pump(tester);

    await tester.enterText(find.byType(TextFormField), 'Wanderfalke');
    await tester.pumpAndSettle();

    expect(controller.text, 'Wanderfalke');
    expect(find.byType(ActionChip), findsNothing);
  });

  testWidgets('tapping a suggestion fills the field, caret at the end', (
    tester,
  ) async {
    // A bare `controller.text =` leaves the caret at offset zero, and the next
    // keystroke would type in front of the word somebody just picked.
    var picked = 0;
    await pump(tester, onPicked: () => picked++);

    await tester.tap(find.widgetWithText(ActionChip, 'Dohle'));
    await tester.pumpAndSettle();

    expect(controller.text, 'Dohle');
    expect(controller.selection.baseOffset, 'Dohle'.length);
    // And it is no longer offered: a chip that does nothing reads as broken.
    expect(find.widgetWithText(ActionChip, 'Dohle'), findsNothing);
    // The callback is what marks the enclosing sheet dirty. A programmatic
    // write to the controller does not reach the Form, so without it the
    // discard guard would let somebody leave a sheet whose species they had
    // just picked.
    expect(picked, 1);
  });

  testWidgets('a failed read costs the chips, never the field', (tester) async {
    // Load-bearing. Somebody looking at a dead jackdaw must not be blocked from
    // writing "Dohle" by a list that could not load.
    when(() => labels.all()).thenAnswer((_) async => throw Exception('nope'));

    await pump(tester);

    expect(find.byType(ActionChip), findsNothing);
    expect(find.byType(TextFormField), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'Dohle');
    expect(controller.text, 'Dohle');
  });
}
