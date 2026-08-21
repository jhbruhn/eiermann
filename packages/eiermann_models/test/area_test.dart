import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

RecordModel areaRecord(Map<String, dynamic> overrides) => RecordModel({
  'id': 'a1',
  'collectionName': 'areas',
  'org': 'org00000default',
  'spot': 's1',
  'name': 'Dachboden Nord',
  'photo': 'dachboden_abc.jpg',
  'previous_photo': '',
  'photo_taken_at': '2026-08-19 09:12:00.000Z',
  'pins_need_review': false,
  'sort_index': 2,
  'note': 'Zugang über die Luke',
  'created': '2026-08-20 23:43:46.862Z',
  'updated': '2026-08-20 23:43:46.862Z',
  ...overrides,
});

void main() {
  group('Area.fromRecord', () {
    test('reads what a Bereich card and the pin editor are built from', () {
      final area = Area.fromRecord(areaRecord(const {}));

      expect(area.id, 'a1');
      expect(area.name, 'Dachboden Nord');
      expect(area.spot, 's1');
      expect(area.org, 'org00000default');
      expect(area.photo, 'dachboden_abc.jpg');
      expect(area.photoTakenAt, DateTime.utc(2026, 8, 19, 9, 12));
      expect(area.sortIndex, 2);
      expect(area.note, 'Zugang über die Luke');
      expect(area.pinsNeedReview, isFalse);
    });

    test('an empty single-file field reads as NO photo, not as a filename', () {
      // A single-file field arrives as the empty string, and `''` passed to a
      // file URL builds a request for the collection's directory — a 404 the
      // UI would draw as a broken image instead of the "no photo yet" state
      // that actually applies.
      final area = Area.fromRecord(areaRecord(const {'photo': ''}));

      expect(area.photo, isNull);
      expect(area.hasPhoto, isFalse);
    });

    test('a Bereich WITH a photo can carry pins', () {
      // The server refuses a pin on an area with no photo (nests.pb.js), so
      // this is what the UI has to consult before offering the gesture.
      expect(Area.fromRecord(areaRecord(const {})).hasPhoto, isTrue);
    });

    test('the review pass is readable: old photo kept AND the flag raised', () {
      // Both halves or neither. A flag with no old photo beside it leaves a
      // reviewer guessing at what moved, which is the one thing the pass exists
      // to prevent.
      final area = Area.fromRecord(
        areaRecord(const {
          'photo': 'neu_xyz.jpg',
          'previous_photo': 'alt_abc.jpg',
          'pins_need_review': true,
        }),
      );

      expect(area.photo, 'neu_xyz.jpg');
      expect(area.previousPhoto, 'alt_abc.jpg');
      expect(area.pinsNeedReview, isTrue);
    });

    test('a missing photo date is null rather than the epoch', () {
      final area = Area.fromRecord(areaRecord(const {'photo_taken_at': ''}));

      expect(area.photoTakenAt, isNull);
    });

    test('no sort_index yet is null, not zero', () {
      // Zero is a real position — the first one — so a Bereich nobody has
      // ordered must not claim it.
      final area = Area.fromRecord(areaRecord(const {'sort_index': null}));

      expect(area.sortIndex, isNull);
    });
  });
}
