import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/nests/nest_sheet.dart';
import 'package:eiermann/features/nests/nests_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/harness.dart';

class _MockNests extends Mock implements NestsRepository {}

const _nest = Nest(
  id: 'n1',
  label: 'N3',
  area: 'a1',
  species: NestSpecies.feralPigeon,
  status: NestStatus.active,
  pinX: 0.4,
  pinY: 0.6,
);

void main() {
  late AppLocalizations de;
  late _MockNests repo;

  setUpAll(() async {
    de = await germanStrings();
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() {
    repo = _MockNests();
    when(() => repo.create(any())).thenAnswer((_) async => _nest);
    when(() => repo.update(any(), any())).thenAnswer((_) async => _nest);
    when(() => repo.forArea(any())).thenAnswer((_) async => []);
  });

  Future<void> pump(
    WidgetTester tester, {
    Nest? nest,
    ({double x, double y})? pin,
    String? suggestedLabel,
    UserRole role = UserRole.member,
  }) async {
    await tester.pumpApp(
      Scaffold(
        body: NestSheet(
          areaId: 'a1',
          nest: nest,
          pin: pin,
          suggestedLabel: suggestedLabel,
        ),
      ),
      overrides: [
        nestsRepositoryProvider.overrideWith((ref) async => repo),
        currentUserProvider.overrideWith(
          (ref) async => AppUser(
            id: 'u1',
            email: 'feld@eiermann.test',
            role: role,
            org: 'org00000default',
          ),
        ),
      ],
    );
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> captureCreate() =>
      verify(() => repo.create(captureAny())).captured.single
          as Map<String, dynamic>;

  Map<String, dynamic> captureUpdate() =>
      verify(() => repo.update('n1', captureAny())).captured.single
          as Map<String, dynamic>;

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.text(de.actionSave));
    await tester.pumpAndSettle();
  }

  group('suggestNestLabel', () {
    test('the first nest of a Bereich is N1', () {
      expect(suggestNestLabel([]), 'N1');
    });

    test('it counts up past what is there', () {
      expect(
        suggestNestLabel([
          _nest.copyWith(label: 'N1'),
          _nest.copyWith(label: 'N2'),
        ]),
        'N3',
      );
    });

    test('it fills a GAP rather than proposing a taken label', () {
      // The label is unique per Bereich, so proposing "N3" when N3 exists would
      // be refused — after the volunteer had already filled the sheet in.
      expect(
        suggestNestLabel([
          _nest.copyWith(label: 'N1'),
          _nest.copyWith(label: 'N3'),
        ]),
        'N2',
      );
    });

    test('a hand-written label does not confuse the count', () {
      expect(suggestNestLabel([_nest.copyWith(label: 'Kamin')]), 'N1');
    });
  });

  testWidgets('a tapped position travels into the create as a PAIR', (
    tester,
  ) async {
    // One write for one gesture. Creating the row first and pinning it after
    // would leave an unnamed nest behind whenever somebody backs out.
    await pump(tester, pin: (x: 0.25, y: 0.75), suggestedLabel: 'N4');

    await save(tester);

    final body = captureCreate();
    expect(body['label'], 'N4');
    expect(body['pin_x'], 0.25);
    expect(body['pin_y'], 0.75);
    expect(body['area'], 'a1');
    expect(body['org'], 'org00000default');
  });

  testWidgets('the suggested label is offered, not imposed', (tester) async {
    await pump(tester, pin: (x: 0.5, y: 0.5), suggestedLabel: 'N4');
    await tester.enterText(find.byType(TextFormField).first, 'Kamin');

    await save(tester);

    expect(captureCreate()['label'], 'Kamin');
  });

  testWidgets('an EDIT never re-sends the pin', (tester) async {
    // The drag on the photo owns the pin. Sending the pair the sheet was opened
    // with would undo a move somebody made in between.
    await pump(tester, nest: _nest);
    await tester.enterText(find.byType(TextFormField).first, 'N9');

    await save(tester);

    final body = captureUpdate();
    expect(body['label'], 'N9');
    expect(body.containsKey('pin_x'), isFalse);
    expect(body.containsKey('pin_y'), isFalse);
    expect(body.containsKey('area'), isFalse);
  });

  testWidgets('a new nest is UNBESTIMMT until somebody says otherwise', (
    tester,
  ) async {
    // The app does not identify species. Defaulting to "city pigeon" would be
    // the app making that call — and it is the one call that can be illegal.
    await pump(tester, pin: (x: 0.5, y: 0.5), suggestedLabel: 'N1');

    await save(tester);

    expect(captureCreate()['species'], NestSpecies.unknown.wire);
  });

  testWidgets('marking a nest GESCHÜTZT is open to a member', (tester) async {
    // The volunteer standing in front of a jackdaw must be able to stop the
    // process immediately, without finding a coordinator first.
    await pump(tester, pin: (x: 0.5, y: 0.5), suggestedLabel: 'N1');

    await tester.tap(find.text(de.nestSpeciesProtected));
    await tester.pumpAndSettle();
    await save(tester);

    expect(captureCreate()['species'], NestSpecies.protected.wire);
  });

  testWidgets('a member cannot take a protected nest BACK', (tester) async {
    // The way out re-enables egg removal on that nest. The hook refuses it too
    // — this is the half that keeps a member from tapping an option that would
    // come back 403.
    await pump(
      tester,
      nest: _nest.copyWith(species: NestSpecies.protected),
    );

    expect(find.text(de.nestProtectedLockedHint), findsOneWidget);
    await tester.tap(find.text(de.nestSpeciesFeralPigeon));
    await tester.pumpAndSettle();
    await save(tester);

    // Still protected: the tap did nothing at all.
    expect(captureUpdate()['species'], NestSpecies.protected.wire);
  });

  testWidgets('the coordination CAN take it back', (tester) async {
    await pump(
      tester,
      nest: _nest.copyWith(species: NestSpecies.protected),
      role: UserRole.coordinator,
    );

    expect(find.text(de.nestProtectedLockedHint), findsNothing);
    await tester.tap(find.text(de.nestSpeciesFeralPigeon));
    await tester.pumpAndSettle();
    await save(tester);

    expect(captureUpdate()['species'], NestSpecies.feralPigeon.wire);
  });

  testWidgets('the species NAME is asked for unless it is a city pigeon', (
    tester,
  ) async {
    // Free text, because a curated list goes stale — and it only makes sense
    // where the species is the open question.
    await pump(tester, pin: (x: 0.5, y: 0.5), suggestedLabel: 'N1');
    expect(find.text(de.nestFieldSpeciesLabel), findsOneWidget);

    await tester.tap(find.text(de.nestSpeciesFeralPigeon));
    await tester.pumpAndSettle();

    expect(find.text(de.nestFieldSpeciesLabel), findsNothing);
  });

  testWidgets('a nameless nest is refused before the request', (tester) async {
    // The label is the caption on the pin. A nest without one cannot be pointed
    // at in an attic, and the server requires it anyway.
    await pump(tester, pin: (x: 0.5, y: 0.5));

    await save(tester);

    verifyNever(() => repo.create(any()));
  });
}
