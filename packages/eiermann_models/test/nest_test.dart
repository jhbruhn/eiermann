import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

RecordModel nestRecord(Map<String, dynamic> overrides) => RecordModel({
  'id': 'n1',
  'collectionName': 'nests',
  'org': 'org00000default',
  'spot': 's1',
  'area': 'a1',
  'label': 'N3',
  'position_hint': 'Balken links',
  'pin_x': 0.42,
  'pin_y': 0.61,
  'photo': '',
  'species': 'feral_pigeon',
  'species_label': '',
  'status': 'active',
  'interval_days': 14,
  'empty_streak': 2,
  'next_due_at': '2026-08-25 00:00:00.000Z',
  'note': '',
  'created': '2026-08-20 23:43:46.862Z',
  'updated': '2026-08-20 23:43:46.862Z',
  ...overrides,
});

void main() {
  group('Nest.fromRecord', () {
    test('reads what a pin and a nest line are drawn from', () {
      final nest = Nest.fromRecord(nestRecord(const {}));

      expect(nest.id, 'n1');
      expect(nest.label, 'N3');
      expect(nest.area, 'a1');
      expect(nest.spot, 's1');
      expect(nest.positionHint, 'Balken links');
      expect(nest.pin, (x: 0.42, y: 0.61));
      expect(nest.species, NestSpecies.feralPigeon);
      expect(nest.status, NestStatus.active);
      expect(nest.intervalDays, 14);
      expect(nest.emptyStreak, 2);
      expect(nest.nextDueAt, DateTime.utc(2026, 8, 25));
    });

    test('a species this build cannot name is null, never a pigeon', () {
      // The one field where guessing is dangerous: reading an unknown value as
      // `feral_pigeon` would tell a volunteer that a jackdaw's clutch may be
      // swapped. §44 BNatSchG says otherwise.
      final nest = Nest.fromRecord(nestRecord(const {'species': 'kestrel'}));

      expect(nest.species, isNull);
      expect(nest.isProtected, isFalse);
    });

    test('a protected nest says so', () {
      final nest = Nest.fromRecord(nestRecord(const {'species': 'protected'}));

      expect(nest.isProtected, isTrue);
    });

    test('interval_days of 0 is NO rhythm, not a zero-day one', () {
      // Measured on the running server: an unset number field comes back as 0,
      // and a nest created before its first check has no rung on the ladder.
      final nest = Nest.fromRecord(nestRecord(const {'interval_days': 0}));

      expect(nest.intervalDays, isNull);
    });

    test('empty_streak of 0 IS a reading — the last check found eggs', () {
      // Same wire value, opposite meaning: a streak of zero is the normal state
      // of a working nest, and reading it as "unknown" would hide it.
      final nest = Nest.fromRecord(nestRecord(const {'empty_streak': 0}));

      expect(nest.emptyStreak, 0);
    });
  });

  group('the pin', () {
    test('an unpinned nest arrives as 0/0 and reads as NO pin', () {
      // Verified against the running server: a nest created without pins comes
      // back `pin_x: 0, pin_y: 0`, because PocketBase has no null for a number
      // field. Drawing that as a pin would put a marker in the top-left corner
      // of the photo for every nest nobody has placed yet.
      final nest = Nest.fromRecord(
        nestRecord(const {'pin_x': 0, 'pin_y': 0}),
      );

      expect(nest.pin, isNull);
      expect(nest.hasPin, isFalse);
    });

    test('zero on ONE axis is still a pin', () {
      // A nest on the left edge, halfway down. Only the pair is ambiguous, and
      // treating any zero as absent would make the whole left edge unpinnable.
      final nest = Nest.fromRecord(
        nestRecord(const {'pin_x': 0, 'pin_y': 0.5}),
      );

      expect(nest.pin, (x: 0.0, y: 0.5));
    });

    test('half a pin is no pin', () {
      // An x with no y would be drawn along the top edge of the photo — a
      // claim about the building that nobody made.
      final nest = Nest.fromRecord(
        nestRecord(const {'pin_x': 0.3, 'pin_y': null}),
      );

      expect(nest.pin, isNull);
    });
  });

  group('normalisePin', () {
    test('never writes the one value that means "unset"', () {
      // The server clamps into 0…1, so a drag into the top-left corner lands on
      // exactly 0/0 — the value the reader has to treat as "no pin". Nudging it
      // by a thousandth (about one pixel at the editor's working width) is what
      // keeps a corner pin a pin.
      expect(normalisePin(0), kPinMin);
      expect(normalisePin(-0.4), kPinMin);
    });

    test('a pin dropped on the far edge stays on it', () {
      // A drag to the edge routinely computes to 1.0000000002, and refusing
      // that would mean a volunteer cannot place the roof nests, which are
      // exactly the ones at the top of the frame.
      expect(normalisePin(1), 1.0);
      expect(normalisePin(1.0000000002), 1.0);
      expect(normalisePin(1.7), 1.0);
    });

    test('an ordinary coordinate is left alone', () {
      expect(normalisePin(0.42), 0.42);
    });

    test('NaN cannot reach the wire', () {
      // A gesture divided by a zero-height box produces NaN, and PocketBase
      // would refuse the whole write with a validation error that names the
      // field but not the cause.
      expect(normalisePin(double.nan), kPinMin);
    });
  });
}
