import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/areas/area_pin_review.dart';
import 'package:eiermann/features/areas/pin_canvas.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/harness.dart';

class _MockAreas extends Mock implements AreasRepository {}

Nest nest({
  required String id,
  String label = 'N1',
  double? x,
  double? y,
  String? hint,
}) => Nest(
  id: id,
  label: label,
  area: 'a1',
  species: NestSpecies.feralPigeon,
  status: NestStatus.active,
  pinX: x,
  pinY: y,
  positionHint: hint,
);

/// A Bereich mid-pass: a new photo, the outgoing one kept, the flag up.
const flagged = Area(
  id: 'a1',
  name: 'Dachboden Nord',
  spot: 's1',
  photo: 'neu.jpg',
  previousPhoto: 'alt.jpg',
  pinsNeedReview: true,
);

void main() {
  late AppLocalizations de;
  late _MockAreas areas;

  setUpAll(() async => de = await germanStrings());

  setUp(() {
    areas = _MockAreas();
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
    required List<Nest> nests,
    required List<PinnedNest> before,
    Set<String> reviewed = const {},
    Area area = flagged,
    List<String> confirmed = const [],
    VoidCallback? onFinish,
  }) => tester.pumpApp(
    Scaffold(
      body: SingleChildScrollView(
        child: AreaPinReview(
          area: area,
          nests: nests,
          before: before,
          canvas: PinCanvas(
            photo: const SizedBox(width: 300, height: 200),
            nests: PinnedNest.fromNests(nests),
          ),
          reviewed: reviewed,
          onConfirm: confirmed.add,
          onFinish: onFinish ?? () {},
        ),
      ),
    ),
    overrides: [
      areasRepositoryProvider.overrideWith((ref) async => areas),
    ],
  );

  /// The position a pin is drawn at on [canvas], read off its [Align].
  ({double x, double y}) drawnAt(WidgetTester tester, Finder canvas) {
    final align = tester.widget<Align>(
      find.descendant(of: canvas, matching: find.byType(Align)).first,
    );
    final at = align.alignment as Alignment;
    return (x: (at.x + 1) / 2, y: (at.y + 1) / 2);
  }

  testWidgets('the outgoing photo keeps the pins WHERE THEY WERE', (
    tester,
  ) async {
    // The whole value of the left-hand picture. Read from the live rows it
    // would show each correction the moment it was made, which is the one
    // thing it must not do: there would be nothing left to compare against,
    // and the pass would be a click-through.
    await pump(
      tester,
      nests: [nest(id: 'n1', x: 0.8, y: 0.8)],
      before: [
        const PinnedNest(id: 'n1', label: 'N1', at: (x: 0.2, y: 0.2)),
      ],
    );

    final canvases = find.byType(PinCanvas);
    expect(canvases, findsNWidgets(2));
    expect(drawnAt(tester, canvases.first), (x: 0.2, y: 0.2));
    expect(drawnAt(tester, canvases.last), (x: 0.8, y: 0.8));
  });

  testWidgets('both pictures are captioned', (tester) async {
    // Two shots of the same attic a year apart are hard to tell apart, and
    // which one is which decides which way a pin gets dragged.
    await pump(
      tester,
      nests: [nest(id: 'n1', x: 0.5, y: 0.5)],
      before: [
        const PinnedNest(id: 'n1', label: 'N1', at: (x: 0.5, y: 0.5)),
      ],
    );

    expect(find.text(de.areaPinReviewBefore), findsOneWidget);
    expect(find.text(de.areaPinReviewAfter), findsOneWidget);
  });

  testWidgets('the pass cannot be finished before every pin was touched', (
    tester,
  ) async {
    await pump(
      tester,
      nests: [
        nest(id: 'n1', x: 0.5, y: 0.5),
        nest(id: 'n2', label: 'N2', x: 0.6, y: 0.6),
      ],
      before: const [],
      reviewed: {'n1'},
    );

    expect(find.text(de.areaPinReviewProgress(1, 2)), findsOneWidget);
    final finish = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, de.areaPinReviewFinishAction),
    );
    expect(
      finish.onPressed,
      isNull,
      reason: 'one unchecked pin still points at the wrong rafter',
    );
  });

  testWidgets('...and can, once every one was', (tester) async {
    var finished = 0;
    await pump(
      tester,
      nests: [nest(id: 'n1', x: 0.5, y: 0.5)],
      before: const [],
      reviewed: {'n1'},
      onFinish: () => finished++,
    );

    expect(find.text(de.areaPinReviewProgress(1, 1)), findsOneWidget);
    await tester.tap(
      find.widgetWithText(FilledButton, de.areaPinReviewFinishAction),
    );
    expect(finished, 1);
  });

  testWidgets('an UNPINNED nest is not part of the pass', (tester) async {
    // It has no coordinate, so nothing about it can have drifted. Counting it
    // would make a pass that cannot be completed: there is no pin to confirm.
    await pump(
      tester,
      nests: [
        nest(id: 'n1', x: 0.5, y: 0.5),
        nest(id: 'n2', label: 'N2'),
      ],
      before: const [],
      reviewed: {'n1'},
    );

    expect(find.text(de.areaPinReviewProgress(1, 1)), findsOneWidget);
    expect(find.text('N2'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, de.areaPinReviewFinishAction),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('confirming a pin reports it, and only it', (tester) async {
    final confirmed = <String>[];
    await pump(
      tester,
      nests: [
        nest(id: 'n1', x: 0.5, y: 0.5, hint: 'Balken links'),
        nest(id: 'n2', label: 'N2', x: 0.6, y: 0.6),
      ],
      before: const [],
      confirmed: confirmed,
    );

    // The position hint is on the line: it is what a pin cannot say, and the
    // only thing that decides where the pin belongs on a picture that no
    // longer matches it.
    expect(find.text('Balken links'), findsOneWidget);
    await tester.tap(
      find
          .descendant(
            of: find.widgetWithText(ListTile, 'N2'),
            matching: find.text(de.areaPinReviewConfirmAction),
          )
          .first,
    );
    expect(confirmed, ['n2']);
  });

  testWidgets('a pin already touched offers no second confirmation', (
    tester,
  ) async {
    await pump(
      tester,
      nests: [nest(id: 'n1', x: 0.5, y: 0.5)],
      before: const [],
      reviewed: {'n1'},
    );

    expect(find.text(de.areaPinReviewConfirmed), findsOneWidget);
    expect(find.text(de.areaPinReviewConfirmAction), findsNothing);
  });

  testWidgets('a flagged Bereich whose old photo is gone stays completable', (
    tester,
  ) async {
    // Only reachable through something nobody designed — a superuser edit, a
    // restored backup. The alternative to completing it is a Bereich that can
    // never lose its warning.
    await pump(
      tester,
      area: const Area(
        id: 'a1',
        name: 'Dachboden Nord',
        spot: 's1',
        photo: 'neu.jpg',
        pinsNeedReview: true,
      ),
      nests: [nest(id: 'n1', x: 0.5, y: 0.5)],
      before: const [],
      reviewed: {'n1'},
    );

    expect(find.text(de.areaPinsNeedReview), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, de.areaPinReviewFinishAction),
          )
          .onPressed,
      isNotNull,
    );
  });
}
