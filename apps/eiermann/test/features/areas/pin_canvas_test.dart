import 'package:eiermann/features/areas/pin_canvas.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/harness.dart';

/// A canvas of a known size, standing in for the photo.
///
/// The real one is a network image that never resolves in a test — and the
/// canvas takes its height from the picture, so without this there would be
/// nothing to divide by and every coordinate would be meaningless.
const _canvasSize = Size(300, 200);

/// A pin as the canvas takes it — mapped through the shared rule, so an
/// unpinned nest (0/0) drops out here exactly as it does in the app.
List<PinnedNest> pins(List<Nest> nests) => PinnedNest.fromNests(nests);

Nest nest({
  required String id,
  String label = 'N1',
  double? x,
  double? y,
  NestSpecies species = NestSpecies.feralPigeon,
}) => Nest(
  id: id,
  label: label,
  area: 'a1',
  species: species,
  status: NestStatus.active,
  pinX: x,
  pinY: y,
);

void main() {
  late AppLocalizations de;
  late List<({double x, double y})> taps;
  late List<(PinnedNest, ({double x, double y}))> moves;
  late List<PinnedNest> opened;

  setUpAll(() async {
    de = await germanStrings();
  });

  setUp(() {
    taps = [];
    moves = [];
    opened = [];
  });

  Future<void> pump(WidgetTester tester, List<Nest> nests) => tester.pumpApp(
    Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        // Inset from the top so a drag that overshoots UPWARDS still lands
        // inside the test view — a pointer event outside it is dropped, and the
        // clamp would then look untested rather than untriggered.
        child: Padding(
          padding: const EdgeInsets.only(top: 120),
          child: SizedBox(
            width: _canvasSize.width,
            child: PinCanvas(
              photo: SizedBox(
                width: _canvasSize.width,
                height: _canvasSize.height,
              ),
              nests: pins(nests),
              onTap: taps.add,
              onMoved: (nest, to) => moves.add((nest, to)),
              onOpen: opened.add,
            ),
          ),
        ),
      ),
    ),
  );

  /// A point on the canvas, as a fraction of it — so the test never depends on
  /// where the canvas happens to sit in the window.
  Offset at(WidgetTester tester, double fx, double fy) {
    final rect = tester.getRect(find.byType(PinCanvas));
    return rect.topLeft + Offset(rect.width * fx, rect.height * fy);
  }

  /// The fractional position a pin is drawn at, read off its [Align].
  Alignment alignmentOf(WidgetTester tester, String label) {
    final align = tester.widget<Align>(
      find.ancestor(of: find.text(label), matching: find.byType(Align)).first,
    );
    return align.alignment as Alignment;
  }

  /// Compares an alignment component-wise, because these are the result of
  /// dividing pixels: 0.5 + 0.1 is 0.6000000000000001, which prints as 0.2 in
  /// an Alignment and is not equal to it.
  void expectAlignment(Alignment actual, Alignment expected) {
    expect(actual.x, closeTo(expected.x, 0.001));
    expect(actual.y, closeTo(expected.y, 0.001));
  }

  testWidgets('a tap in the middle is 0.5 / 0.5, whatever the box measures', (
    tester,
  ) async {
    // The whole point of normalised coordinates: the same nest on a phone, on a
    // desktop and on a re-cropped photo has to come out at the same place.
    await pump(tester, []);

    await tester.tapAt(at(tester, 0.5, 0.5));
    await tester.pumpAndSettle();

    expect(taps.single.x, closeTo(0.5, 0.001));
    expect(taps.single.y, closeTo(0.5, 0.001));
  });

  testWidgets('a tap in a corner is normalised, not left at 0 / 0', (
    tester,
  ) async {
    // The one value the wire cannot tell from "unset". A pin written there
    // would vanish on the next read.
    await pump(tester, []);

    await tester.tapAt(at(tester, 0, 0));
    await tester.pumpAndSettle();

    expect(taps.single, (x: kPinMin, y: kPinMin));
  });

  testWidgets('a tap in the far corner stays inside the photo', (tester) async {
    await pump(tester, []);

    await tester.tapAt(at(tester, 1, 1) - const Offset(1, 1));
    await tester.pumpAndSettle();

    expect(taps.single.x, lessThanOrEqualTo(1));
    expect(taps.single.y, lessThanOrEqualTo(1));
    expect(taps.single.x, greaterThan(0.99));
  });

  testWidgets('a pin is drawn where its coordinates say', (tester) async {
    // Fractional alignment, so the drawing does not need the pixel height the
    // image decides — and cannot drift from the maths the gesture uses.
    await pump(tester, [nest(id: 'n1', x: 0.25, y: 0.75)]);

    // Alignment runs -1…1 across the box, so 0.25 → -0.5 and 0.75 → 0.5.
    expectAlignment(alignmentOf(tester, 'N1'), const Alignment(-0.5, 0.5));
  });

  testWidgets('an UNPINNED nest is not drawn on the photo at all', (
    tester,
  ) async {
    // 0/0 is what an unpinned nest arrives as. Drawing it would put every nest
    // nobody has placed in the top-left corner, claiming a position.
    await pump(tester, [
      nest(id: 'n1', label: 'Ohne Pin', x: 0, y: 0),
      nest(id: 'n2', label: 'Mit Pin', x: 0.5, y: 0.5),
    ]);

    expect(find.text('Ohne Pin'), findsNothing);
    expect(find.text('Mit Pin'), findsOneWidget);
  });

  testWidgets('tapping a pin opens its nest instead of placing a new one', (
    tester,
  ) async {
    await pump(tester, [nest(id: 'n1', x: 0.5, y: 0.5)]);

    await tester.tap(find.text('N1'));
    await tester.pumpAndSettle();

    expect(opened.single.id, 'n1');
    expect(taps, isEmpty, reason: 'the tap must not also place a nest');
  });

  testWidgets('dragging a pin follows the finger, then reports ONE move', (
    tester,
  ) async {
    // The drag is local until it is dropped: writing on every frame would be a
    // request per pixel, and a half-finished drag is not a decision.
    await pump(tester, [nest(id: 'n1', x: 0.5, y: 0.5)]);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('N1')),
    );
    // 60px right and 20px down on a 300x200 canvas: +0.2 / +0.1.
    await gesture.moveBy(const Offset(30, 10));
    await tester.pump();
    await gesture.moveBy(const Offset(30, 10));
    await tester.pump();
    expect(moves, isEmpty, reason: 'nothing is written mid-drag');
    expectAlignment(alignmentOf(tester, 'N1'), const Alignment(0.4, 0.2));

    await gesture.up();
    await tester.pumpAndSettle();

    final (moved, to) = moves.single;
    expect(moved.id, 'n1');
    expect(to.x, closeTo(0.7, 0.001));
    expect(to.y, closeTo(0.6, 0.001));
  });

  testWidgets('a pin dragged off the edge is clamped, not lost', (
    tester,
  ) async {
    // Roof nests are exactly the ones at the top of the frame, and a drag that
    // overshoots must place them on the edge rather than nowhere.
    await pump(tester, [nest(id: 'n1', x: 0.5, y: 0.5)]);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('N1')),
    );
    // Far right and far enough up to leave the canvas, but still inside the
    // view: 200px right of centre is past the 300px-wide canvas, and 150px up
    // from the middle of a 200px-tall canvas is above its top edge.
    await gesture.moveBy(const Offset(200, -150));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(moves.single.$2.x, closeTo(1, 0.001));
    expect(moves.single.$2.y, closeTo(kPinMin, 0.001));
  });

  testWidgets('a marked pin draws the MARK, not the species', (tester) async {
    // The visit flow marks a nest it has already recorded. All three parts
    // move together on purpose: colour alone fails WCAG 1.4.1, and a screen
    // reader would otherwise still be read the species the pin no longer shows.
    const mark = PinMark(
      icon: Icons.swap_horiz,
      colour: Color(0xFF00FF00),
      label: 'getauscht',
    );
    await tester.pumpApp(
      Scaffold(
        body: SizedBox(
          width: _canvasSize.width,
          child: PinCanvas(
            photo: SizedBox(
              width: _canvasSize.width,
              height: _canvasSize.height,
            ),
            nests: const [
              PinnedNest(
                id: 'n1',
                label: 'N1',
                at: (x: 0.5, y: 0.5),
                species: NestSpecies.feralPigeon,
                mark: mark,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byIcon(mark.icon), findsOneWidget);
    expect(find.byIcon(Icons.egg_outlined), findsNothing);
    final pin = tester.widget<Container>(
      find
          .ancestor(
            of: find.byIcon(mark.icon),
            matching: find.byType(Container),
          )
          .first,
    );
    expect((pin.decoration! as BoxDecoration).color, mark.colour);
    // What a screen reader is handed: the mark's words, not the species'.
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp(mark.label)), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(de.nestSpeciesFeralPigeon)),
      findsNothing,
    );
    // Inline rather than in a tearDown: the handle has to be gone before the
    // test ENDS, and a tearDown runs after the check that it is.
    semantics.dispose();
  });
}
