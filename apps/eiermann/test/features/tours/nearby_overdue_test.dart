import 'package:eiermann/features/tours/nearby_overdue.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

SpotOverview _spot({
  required String id,
  required String name,
  required SpotUrgency level,
  double? lat,
  double? lon,
}) => SpotOverview(
  id: id,
  name: name,
  urgency: level.rank,
  geo: lat == null || lon == null ? null : GeoPoint(lat: lat, lon: lon),
);

void main() {
  // Two points about 1.1 km apart on the same latitude, and one about 8 km
  // away. Real numbers rather than a mocked distance: the ranking is the thing
  // being tested and it is only as good as the arithmetic under it.
  const here = (lat: 53.1435, lon: 8.2146);

  group('overdueNearby', () {
    test('only the ranks that are actually late are suggested', () {
      // Due-this-week is real work, but padding a shortlist with it buries the
      // buildings that are already late. A paused Spot is deliberately out of
      // the rhythm and an Erkundung needs a conversation, not a visit.
      final list = overdueNearby(
        spots: [
          _spot(id: 'a', name: 'Überfällig', level: SpotUrgency.overdue),
          _spot(id: 'b', name: 'Heute', level: SpotUrgency.dueToday),
          _spot(id: 'c', name: 'Diese Woche', level: SpotUrgency.dueSoon),
          _spot(id: 'd', name: 'Im Rhythmus', level: SpotUrgency.inRhythm),
          _spot(id: 'e', name: 'Pausiert', level: SpotUrgency.paused),
          _spot(id: 'f', name: 'Erkundung', level: SpotUrgency.prospect),
        ],
      );

      expect(list.map((n) => n.spot.id), ['a', 'b']);
    });

    test('a rank this build has no name for is left out, not guessed at', () {
      final list = overdueNearby(
        spots: const [SpotOverview(id: 'x', name: 'Neu', urgency: 99)],
      );

      expect(list, isEmpty);
    });

    test('nearest first once there is a position', () {
      final list = overdueNearby(
        spots: [
          _spot(
            id: 'far',
            name: 'Weit',
            level: SpotUrgency.overdue,
            lat: 53.2135,
            lon: 8.2146,
          ),
          _spot(
            id: 'near',
            name: 'Nah',
            level: SpotUrgency.overdue,
            lat: 53.1535,
            lon: 8.2146,
          ),
        ],
        from: here,
      );

      expect(list.map((n) => n.spot.id), ['near', 'far']);
      expect(list.first.metres, lessThan(list.last.metres!));
    });

    test('a building with no pin sorts last but is NOT dropped', () {
      // A Spot nobody has placed on the map is still overdue. Hiding it would
      // make the list quietly incomplete in exactly the way that loses
      // buildings.
      final list = overdueNearby(
        spots: [
          _spot(id: 'unpinned', name: 'Ohne Pin', level: SpotUrgency.overdue),
          _spot(
            id: 'pinned',
            name: 'Mit Pin',
            level: SpotUrgency.overdue,
            lat: 53.2135,
            lon: 8.2146,
          ),
        ],
        from: here,
      );

      expect(list.map((n) => n.spot.id), ['pinned', 'unpinned']);
      expect(list.last.metres, isNull);
    });

    test('with no position it falls back to urgency, then name', () {
      // The same order every other list in this app uses. Reordering by nothing
      // would be worse than either, which is why the screen says which order it
      // is showing.
      final list = overdueNearby(
        spots: [
          _spot(id: 'b', name: 'Bertastraße', level: SpotUrgency.dueToday),
          _spot(id: 'z', name: 'Zeppelinweg', level: SpotUrgency.overdue),
          _spot(id: 'a', name: 'Ammerland', level: SpotUrgency.overdue),
        ],
      );

      expect(list.map((n) => n.spot.id), ['a', 'z', 'b']);
      expect(list.every((n) => n.metres == null), isTrue);
    });

    test('a distance is never computed without a position', () {
      final list = overdueNearby(
        spots: [
          _spot(
            id: 'a',
            name: 'A',
            level: SpotUrgency.overdue,
            lat: 53.1,
            lon: 8.2,
          ),
        ],
      );

      expect(list.single.metres, isNull);
    });

    test('buildings already on the round are not suggested again', () {
      // Suggesting one somebody has just visited is how a round gets walked
      // twice.
      final list = overdueNearby(
        spots: [
          _spot(id: 'done', name: 'Erledigt', level: SpotUrgency.overdue),
          _spot(id: 'todo', name: 'Offen', level: SpotUrgency.overdue),
        ],
        exclude: {'done'},
      );

      expect(list.map((n) => n.spot.id), ['todo']);
    });

    test('the cap applies AFTER sorting, so the nearest survive it', () {
      final list = overdueNearby(
        spots: [
          for (var i = 0; i < 5; i++)
            _spot(
              id: 'p$i',
              name: 'P$i',
              level: SpotUrgency.overdue,
              // Descending closeness: p4 is nearest.
              lat: 53.1435 + (5 - i) * 0.01,
              lon: 8.2146,
            ),
        ],
        from: here,
        limit: 2,
      );

      expect(list.map((n) => n.spot.id), ['p4', 'p3']);
    });
  });

  group('distanceMetres', () {
    test('0.01° of latitude is about 1.1 km', () {
      final metres = distanceMetres(
        fromLat: 53.1435,
        fromLon: 8.2146,
        toLat: 53.1535,
        toLon: 8.2146,
      );

      expect(metres, closeTo(1112, 5));
    });

    test('the same point is zero, not a rounding artefact', () {
      expect(
        distanceMetres(
          fromLat: 53.1435,
          fromLon: 8.2146,
          toLat: 53.1435,
          toLon: 8.2146,
        ),
        closeTo(0, 0.001),
      );
    });

    test('it is symmetric', () {
      final there = distanceMetres(
        fromLat: 53.1435,
        fromLon: 8.2146,
        toLat: 53.5511,
        toLon: 9.9937,
      );
      final back = distanceMetres(
        fromLat: 53.5511,
        fromLon: 9.9937,
        toLat: 53.1435,
        toLon: 8.2146,
      );

      expect(there, closeTo(back, 0.001));
    });
  });
}
