import 'package:eiermann/features/visits/packing.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter_test/flutter_test.dart';

NestState nest({
  String id = 'n1',
  int real = 0,
  int dummy = 0,
  NestSpecies species = NestSpecies.feralPigeon,
  NestStatus status = NestStatus.active,
}) => NestState(
  id: id,
  label: id.toUpperCase(),
  area: 'a1',
  urgency: 3,
  species: species,
  status: status,
  realCount: real,
  dummyCount: dummy,
);

void main() {
  test("the concept's own example comes out at three Attrappen", () {
    // Straight off the drawing in the concept: N1 two dummies, N2 empty, N3 one
    // dummy and one real egg, N4 a jackdaw. 0 + 2 + 1 + 0 = 3, which is the
    // number on the mockup. If this ever disagrees with the drawing, the
    // drawing is the specification.
    expect(
      dummiesToPack([
        nest(dummy: 2),
        nest(id: 'n2'),
        nest(id: 'n3', dummy: 1, real: 1),
        nest(id: 'n4', species: NestSpecies.protected, real: 2),
      ]),
      3,
    );
  });

  test('an empty nest still needs a full clutch packed', () {
    // Nothing to swap TODAY is not nothing to swap when you get there: what the
    // birds laid overnight is not knowable, and over-packing costs nothing
    // while driving back costs an afternoon.
    expect(dummiesToPack([nest()]), kTypicalClutchSize);
  });

  test('a nest already full of dummies needs none', () {
    expect(dummiesToPack([nest(dummy: 2)]), 0);
    // And more dummies than a clutch never goes negative.
    expect(dummiesToPack([nest(dummy: 5)]), 0);
  });

  test('a protected nest is excluded, not counted', () {
    // Every egg mutation on it is refused server-side. Counting it would send
    // somebody up a ladder with an Attrappe they may not use.
    expect(dummiesToPack([nest(species: NestSpecies.protected)]), 0);
  });

  test('a nest that is gone is excluded too', () {
    // There is nowhere to put an egg.
    expect(dummiesToPack([nest(status: NestStatus.gone)]), 0);
  });

  test('no nests at all is no Attrappen', () {
    // And the screen says so out loud rather than hiding the line: zero is a
    // real answer, a missing line reads as "not computed yet".
    expect(dummiesToPack(const []), 0);
  });
}
