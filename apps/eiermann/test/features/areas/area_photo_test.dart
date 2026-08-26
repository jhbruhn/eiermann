import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/areas/area_photo.dart';
import 'package:eiermann/features/areas/pin_canvas.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/harness.dart';

class _MockAreas extends Mock implements AreasRepository {}

/// The width the canvas is given, so the reserved height is a number this test
/// can name rather than whatever the surface happens to be.
const _width = 400.0;

void main() {
  late _MockAreas areas;

  setUp(() {
    areas = _MockAreas();
    when(
      () => areas.fileUrl(any(), any(), thumb: any(named: 'thumb')),
    ).thenReturn(Uri.parse('http://localhost:8091/api/files/a1/dach.jpg'));
  });

  const area = Area(
    id: 'a1',
    spot: 's1',
    name: 'Dachboden',
    photo: 'dach.jpg',
  );

  const nest = Nest(
    id: 'n1',
    label: 'N1',
    area: 'a1',
    species: NestSpecies.feralPigeon,
    status: NestStatus.active,
    pinX: 0.5,
    pinY: 0.5,
  );

  /// The canvas under a fixed width, at the top left so its rect is readable.
  ///
  /// No image ever resolves in a widget test — which is exactly the state this
  /// file is about, so nothing is stubbed to make one.
  Future<void> pumpCanvas(WidgetTester tester, {Widget? around}) async {
    await tester.pumpApp(
      Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: _width,
            child: around ?? const AreaPhoto(area: area, showAsCanvas: true),
          ),
        ),
      ),
      overrides: [
        areasRepositoryProvider.overrideWith((ref) async => areas),
      ],
    );
    await tester.pump();
  }

  testWidgets('the canvas RESERVES its box while the photo is on its way', (
    tester,
  ) async {
    // Without the reservation the height is whatever the image path happens to
    // produce: nothing at all while the bytes are on their way, and the WHOLE
    // of the parent once the fetch has failed and the retry tile stands there
    // (400x600 here, measured against the version before this test). On the
    // visit flow neither is cosmetic — the nest rows sit under the photo, and
    // they move while somebody is reaching for one.
    //
    // A reserved box rather than a minimum height, which would make the box
    // TALLER than a panorama shot and drift every pin upwards.
    await pumpCanvas(tester);

    expect(
      tester.getSize(find.byType(AreaCanvasPhoto)),
      const Size(_width, _width / (16 / 10)),
    );
  });

  testWidgets('a pin on the reserved box can still be hit', (tester) async {
    // The reason this is worth a test of its own: the canvas takes its height
    // from the picture, so with no picture there is no surface to speak of —
    // and a pin over it cannot be tapped at all. That is what stopped the visit
    // flow from being tested through its own photo. It passes here because the
    // box is reserved, not because an image arrived; nothing stubs one.
    final opened = <PinnedNest>[];
    await pumpCanvas(
      tester,
      around: PinCanvas(
        photo: const AreaPhoto(area: area, showAsCanvas: true),
        nests: PinnedNest.fromNests(const [nest]),
        onOpen: opened.add,
      ),
    );

    await tester.tap(find.text('N1'));
    expect(opened.single.id, 'n1');
  });
}
