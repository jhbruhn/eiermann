import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/rhythm/rhythm_settings_screen.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/harness.dart';

class _MockRhythm extends Mock implements RhythmRepository {}

const _defaults = RhythmSettings(
  baseIntervalDays: 7,
  emptyChecksPerStep: 3,
  intervalSteps: [7, 14, 28],
  halfClutchReturnDays: 4,
  pauseAutoResume: true,
);

const _coordinator = AppUser(
  id: 'u-coord',
  email: 'rita@eiermann.test',
  name: 'Rita',
  role: UserRole.coordinator,
  org: 'org00000default',
);

const _member = AppUser(
  id: 'u-member',
  email: 'feld@eiermann.test',
  name: 'Feldteam',
  role: UserRole.member,
  org: 'org00000default',
);

void main() {
  late AppLocalizations de;
  late _MockRhythm rhythm;

  setUpAll(() async {
    de = await germanStrings();
    registerFallbackValue(_defaults);
  });

  setUp(() {
    rhythm = _MockRhythm();
    when(rhythm.fetch).thenAnswer((_) async => _defaults);
    when(() => rhythm.save(any())).thenAnswer((_) async => _defaults);
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    AppUser me = _coordinator,
  }) async {
    // Tall: the explainer card, four fields, three ladder rungs and the save
    // button do not fit 800x600, and a `ListView` does not build what is below
    // the fold — a tap landing off-screen reads as "the control is missing".
    tester.useSurface(const Size(900, 2000));
    await tester.pumpApp(
      const RhythmSettingsScreen(),
      overrides: [
        rhythmRepositoryProvider.overrideWith((ref) async => rhythm),
        currentUserProvider.overrideWith((ref) async => me),
      ],
    );
    await tester.pumpAndSettle();
  }

  RhythmSettings savedSettings() {
    final captured = verify(() => rhythm.save(captureAny())).captured;
    return captured.last as RhythmSettings;
  }

  testWidgets('the ladder is explained before it is offered for editing', (
    tester,
  ) async {
    // Four number fields with no model behind them make somebody guess. This is
    // the one place the ladder gets stated in full — including the asymmetry it
    // is built on.
    await pumpSettings(tester);

    expect(find.text(de.rhythmExplainer), findsOneWidget);
    expect(find.text(de.rhythmBaseLabel), findsOneWidget);
  });

  testWidgets('the last rung is marked as the cap', (tester) async {
    // "Reached and not exceeded" is the property somebody has to understand
    // before editing: a nest empty twenty times running still comes back round
    // every 28 days, because anything with a roof over it can be reoccupied.
    await pumpSettings(tester);

    expect(find.text(de.rhythmLadderRung(1, 7)), findsOneWidget);
    expect(find.text(de.rhythmLadderRung(2, 14)), findsOneWidget);
    expect(find.text(de.rhythmLadderCapRung(3, 28)), findsOneWidget);
  });

  testWidgets('a member sees the numbers and can change none of them', (
    tester,
  ) async {
    // Both halves are deliberate. Hiding them would leave every member acting
    // on dates whose origin they cannot see, and a date you are told to trust
    // without seeing where it came from is a date people override.
    await pumpSettings(tester, me: _member);

    expect(find.text(de.rhythmExplainer), findsOneWidget);
    expect(find.text(de.rhythmReadOnlyHint), findsOneWidget);
    expect(find.text(de.actionSave), findsNothing);

    final field = tester.widget<TextFormField>(
      find.widgetWithText(TextFormField, de.rhythmBaseLabel),
    );
    expect(field.enabled, isFalse);
  });

  testWidgets('saving sends all five values, not just the changed one', (
    tester,
  ) async {
    // The route is a partial PATCH, but this form shows all five at once — so
    // all five are what the reader looked at and pressed save on. A form that
    // submitted only what it believed had changed would be a form whose idea of
    // "changed" is the thing that goes wrong.
    await pumpSettings(tester);

    await tester.enterText(
      find.widgetWithText(TextFormField, de.rhythmHalfClutchLabel),
      '6',
    );
    await tester.tap(find.text(de.actionSave));
    await tester.pumpAndSettle();

    final sent = savedSettings();
    expect(sent.halfClutchReturnDays, 6);
    expect(sent.baseIntervalDays, 7);
    expect(sent.emptyChecksPerStep, 3);
    expect(sent.intervalSteps, [7, 14, 28]);
    expect(sent.pauseAutoResume, isTrue);
  });

  testWidgets('a rung can be lengthened, and the new ladder is what is sent', (
    tester,
  ) async {
    // Rung by rung, never a "7, 14, 28" text field: that would put a second
    // parser for these numbers in the client, which is the exact shape this
    // whole feature is arranged to avoid.
    await pumpSettings(tester);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.add).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(de.actionSave));
    await tester.pumpAndSettle();

    expect(savedSettings().intervalSteps, [8, 14, 28]);
  });

  testWidgets('the last rung cannot be removed', (tester) async {
    // `intervalFor` indexes into this list and the route refuses an empty one.
    // A control that produces a guaranteed refusal is worse than no control.
    when(rhythm.fetch).thenAnswer(
      (_) async => _defaults.copyWith(intervalSteps: const [7]),
    );
    await pumpSettings(tester);

    final remove = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.close),
    );
    expect(remove.onPressed, isNull);
  });

  testWidgets('a ladder below the base warns BEFORE the round trip', (
    tester,
  ) async {
    // The server refuses this, and that refusal is the rule. Saying it here as
    // well means nobody has to decode a code to learn what they typed wrong.
    await pumpSettings(tester);

    await tester.enterText(
      find.widgetWithText(TextFormField, de.rhythmBaseLabel),
      '14',
    );
    await tester.pumpAndSettle();

    expect(find.text(de.rhythmLadderBelowBaseWarning(14)), findsOneWidget);
  });

  testWidgets('a descending ladder warns too', (tester) async {
    when(rhythm.fetch).thenAnswer(
      (_) async => _defaults.copyWith(intervalSteps: const [7, 14, 13]),
    );
    await pumpSettings(tester);

    expect(find.text(de.rhythmLadderDescendingWarning), findsOneWidget);
  });

  testWidgets("a refusal is shown in the reader's own language", (
    tester,
  ) async {
    // The hook sends `rhythm_steps_below_base` and nothing else — it does not
    // know which language the reader speaks. The sentence lives here.
    when(() => rhythm.save(any())).thenThrow(
      const RepositoryException(
        'refused',
        kind: RepositoryErrorKind.validation,
        serverCodes: ['rhythm_steps_below_base'],
      ),
    );
    await pumpSettings(tester);

    await tester.tap(find.text(de.actionSave));
    await tester.pumpAndSettle();

    expect(find.text(de.serverErrorRhythmStepsBelowBase), findsOneWidget);
  });

  testWidgets('a saved change re-reads rather than trusting what was typed', (
    tester,
  ) async {
    // The server normalises — a "7" becomes 7, and a value it adjusted has to
    // reach the screen as the SERVER sees it. A form that kept showing its own
    // input is exactly the drift this route exists to prevent.
    await pumpSettings(tester);

    await tester.tap(find.text(de.actionSave));
    await tester.pumpAndSettle();

    verify(rhythm.fetch).called(2);
    expect(find.text(de.rhythmSaved), findsOneWidget);
  });
}
