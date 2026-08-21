import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/areas/area_editor_screen.dart';
import 'package:eiermann/features/areas/pin_canvas.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/harness.dart';

class _MockAreas extends Mock implements AreasRepository {}

class _MockNests extends Mock implements NestsRepository {}

Nest nest({
  required String id,
  String label = 'N1',
  double? x,
  double? y,
}) => Nest(
  id: id,
  label: label,
  area: 'a1',
  species: NestSpecies.feralPigeon,
  status: NestStatus.active,
  pinX: x,
  pinY: y,
);

void main() {
  late AppLocalizations de;
  late _MockAreas areas;
  late _MockNests nests;

  setUpAll(() async {
    de = await germanStrings();
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() {
    areas = _MockAreas();
    nests = _MockNests();
    when(
      () => areas.fileUrl(
        any(),
        any(),
        thumb: any(named: 'thumb'),
        token: any(named: 'token'),
      ),
    ).thenReturn(Uri.parse('http://pb.test/api/files/areas/a1/foto.jpg'));
  });

  Future<void> pump(
    WidgetTester tester, {
    required Area area,
    List<Nest> rows = const [],
  }) async {
    when(() => areas.getOne(any())).thenAnswer((_) async => area);
    when(() => nests.forArea(any())).thenAnswer((_) async => rows);
    await tester.pumpApp(
      const AreaEditorScreen(areaId: 'a1'),
      overrides: [
        areasRepositoryProvider.overrideWith((ref) async => areas),
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

  const withPhoto = Area(
    id: 'a1',
    name: 'Dachboden Nord',
    spot: 's1',
    photo: 'foto.jpg',
  );

  testWidgets('a Bereich with no photo offers the PHOTO, not a pin tool', (
    tester,
  ) async {
    // There is nothing to pin on. A disabled pin tool would leave the reader
    // looking for the enabled one.
    await pump(
      tester,
      area: const Area(id: 'a1', name: 'Leer', spot: 's1'),
    );

    expect(find.text(de.areaPhotoMissingHint), findsWidgets);
    expect(find.byType(PinCanvas), findsNothing);
    verifyNever(() => nests.forArea(any()));
  });

  testWidgets('both gestures are named — neither is discoverable on a photo', (
    tester,
  ) async {
    await pump(tester, area: withPhoto);

    expect(find.text(de.areaEditorHint), findsOneWidget);
    expect(find.byType(PinCanvas), findsOneWidget);
  });

  testWidgets('a nest that is not on the photo is COUNTED, not hidden', (
    tester,
  ) async {
    // A photo that quietly omits nests reads as the complete picture of a
    // Bereich. 0/0 is what an unpinned nest arrives as.
    await pump(
      tester,
      area: withPhoto,
      rows: [
        nest(id: 'n1', x: 0.5, y: 0.5),
        nest(id: 'n2', label: 'N2', x: 0, y: 0),
        nest(id: 'n3', label: 'N3'),
      ],
    );

    expect(find.text(de.areaEditorUnpinned(2)), findsOneWidget);
    // Each unplaced nest is named, so it can be selected and placed.
    expect(find.widgetWithText(ChoiceChip, 'N2'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'N3'), findsOneWidget);
  });

  testWidgets('nothing is said about unplaced nests when there are none', (
    tester,
  ) async {
    await pump(
      tester,
      area: withPhoto,
      rows: [nest(id: 'n1', x: 0.5, y: 0.5)],
    );

    expect(find.text(de.areaEditorUnpinned(1)), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
  });

  testWidgets('selecting a nest to place says so, by name', (tester) async {
    // Otherwise the next tap reads as "new nest" and the volunteer ends up with
    // two rows for one hole in the wall.
    await pump(
      tester,
      area: withPhoto,
      rows: [nest(id: 'n2', label: 'N2', x: 0, y: 0)],
    );

    await tester.tap(find.widgetWithText(ChoiceChip, 'N2'));
    await tester.pumpAndSettle();

    expect(find.text(de.areaEditorPlacingHint('N2')), findsOneWidget);
    expect(find.text(de.areaEditorHint), findsNothing);
  });
}
