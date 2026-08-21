import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

RecordModel stateRecord(Map<String, dynamic> overrides) => RecordModel({
  'id': 'n1',
  'collectionName': 'nest_state',
  'org': 'org00000default',
  'spot': 's1',
  'area': 'a1',
  'label': 'N3',
  'position_hint': 'Balken links',
  'pin_x': 0.4,
  'pin_y': 0.6,
  'photo': '',
  'species': 'feral_pigeon',
  'species_label': '',
  'status': 'active',
  'interval_days': 14,
  'empty_streak': 0,
  'next_due_at': '2026-08-25 00:00:00.000Z',
  'note': '',
  'real_count': 1,
  'dummy_count': 2,
  'oldest_since': '2026-08-14 09:00:00.000Z',
  'last_checked_at': '2026-08-19 09:00:00.000Z',
  'urgency': 2,
  'created': '2026-08-01 09:00:00.000Z',
  'updated': '2026-08-19 09:00:00.000Z',
  ...overrides,
});

void main() {
  group('NestState.fromRecord', () {
    test('reads the whole line the dossier draws', () {
      final row = NestState.fromRecord(stateRecord(const {}));

      expect(row.label, 'N3');
      expect(row.positionHint, 'Balken links');
      expect(row.realCount, 1);
      expect(row.dummyCount, 2);
      expect(row.eggCount, 3);
      expect(row.isEmpty, isFalse);
      expect(row.level, NestUrgency.dueThisWeek);
      expect(row.oldestSince, DateTime.utc(2026, 8, 14, 9));
      expect(row.lastCheckedAt, DateTime.utc(2026, 8, 19, 9));
    });

    test('an empty nest is empty, not unknown', () {
      // Zero eggs is a real reading and the most common one: it is what a nest
      // looks like after a swap was collected. `pbCount` would read it as null.
      final row = NestState.fromRecord(
        stateRecord(const {'real_count': 0, 'dummy_count': 0}),
      );

      expect(row.eggCount, 0);
      expect(row.isEmpty, isTrue);
    });

    test('a rank this build cannot name stays unnamed', () {
      // The server gained a rung. Drawing it as "in Rhythmus" would state
      // something untrue about a nest somebody has to visit.
      final row = NestState.fromRecord(stateRecord(const {'urgency': 9}));

      expect(row.urgency, 9);
      expect(row.level, isNull);
    });

    test('protected and gone are readable off the row', () {
      expect(
        NestState.fromRecord(
          stateRecord(const {'species': 'protected', 'urgency': 4}),
        ).isProtected,
        isTrue,
      );
      expect(
        NestState.fromRecord(
          stateRecord(const {'status': 'gone', 'urgency': 5}),
        ).isGone,
        isTrue,
      );
    });
  });

  group('the age on the line', () {
    test('is measured from the OLDEST egg where there is one', () {
      // That is the number the work turns on: a dummy that has sat for months
      // is a nest the birds have given up on, which beats "checked recently".
      final row = NestState.fromRecord(stateRecord(const {}));

      expect(row.ageSince, DateTime.utc(2026, 8, 14, 9));
      expect(row.ageInDays(DateTime.utc(2026, 8, 21, 9)), 7);
    });

    test('falls back to the last check for an empty nest', () {
      final row = NestState.fromRecord(
        stateRecord(const {
          'real_count': 0,
          'dummy_count': 0,
          'oldest_since': '',
        }),
      );

      expect(row.ageSince, DateTime.utc(2026, 8, 19, 9));
      expect(row.ageInDays(DateTime.utc(2026, 8, 21, 9)), 2);
    });

    test('is NULL when nothing has happened to the nest at all', () {
      // A nest drawn on the photo and never visited. Reporting that as "0 days"
      // would read as "checked today".
      final row = NestState.fromRecord(
        stateRecord(const {
          'real_count': 0,
          'dummy_count': 0,
          'oldest_since': '',
          'last_checked_at': '',
        }),
      );

      expect(row.ageSince, isNull);
      expect(row.ageInDays(DateTime.utc(2026, 8, 21)), isNull);
    });

    test('counts LOCAL calendar days, not 24-hour blocks', () {
      // The trap: PocketBase stores UTC, so an egg recorded just after midnight
      // in CEST is stored on the PREVIOUS UTC day. Subtracting the raw stamps
      // then reports "1 day" on the very morning it was recorded.
      //
      // Both ends are built from LOCAL wall-clock times and converted, so the
      // assertion is true in every zone. It only DISCRIMINATES where the
      // offset moves the date — which is the honest limit of this test: on a
      // UTC machine (CI) a raw-timestamp implementation would pass it too. The
      // sweep that forces every date through `formatLocalDate` is the other
      // half of this guarantee.
      final justAfterMidnight = DateTime(2026, 8, 21, 0, 30);
      final lateSameDay = DateTime(2026, 8, 21, 23, 30);
      final row = NestState.fromRecord(
        stateRecord({
          'oldest_since': justAfterMidnight.toUtc().toIso8601String(),
        }),
      );

      expect(row.ageInDays(lateSameDay), 0);
    });
  });
}
