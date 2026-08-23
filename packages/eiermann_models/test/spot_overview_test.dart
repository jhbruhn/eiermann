import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

RecordModel overviewRecord(Map<String, dynamic> overrides) => RecordModel({
  'id': 's1',
  'collectionName': 'spot_overview',
  'org': 'org00000default',
  'name': 'Bahnhofstraße 12',
  'street': 'Bahnhofstraße 12',
  'postal_code': '26122',
  'city': 'Oldenburg',
  'geo': {'lon': 8.2146, 'lat': 53.1435},
  'geo_confirmed': true,
  'phase': 'active',
  'prospect_stage': '',
  'paused_until': '',
  'closed_reason': '',
  'access_note': '',
  'facade_photo': '',
  'next_due_at': '2026-08-15 00:00:00.000Z',
  'contact_count': 2,
  'primary_contact_count': 1,
  'urgency': 0,
  'created': '2026-08-20 23:43:46.862Z',
  'updated': '2026-08-20 23:43:46.862Z',
  ...overrides,
});

void main() {
  group('SpotOverview.fromRecord', () {
    test('reads the counts and the rank a row draws from', () {
      final row = SpotOverview.fromRecord(overviewRecord(const {}));

      expect(row.contactCount, 2);
      expect(row.primaryContactCount, 1);
      expect(row.urgency, 0);
      expect(row.level, SpotUrgency.overdue);
      expect(row.addressLine, 'Bahnhofstraße 12, 26122 Oldenburg');
    });

    test('a computed column arriving as a QUOTED number still reads', () {
      // PocketBase types a view's columns by inference and reports a computed
      // one as `json`, so the counted columns can arrive string-encoded rather
      // than as numbers. Reading them with a plain cast is how a list starts
      // throwing the day the view is recreated.
      final row = SpotOverview.fromRecord(
        overviewRecord(const {
          'urgency': '1',
          'contact_count': '4',
          'primary_contact_count': '2',
        }),
      );

      expect(row.urgency, 1);
      expect(row.level, SpotUrgency.dueToday);
      expect(row.contactCount, 4);
      expect(row.primaryContactCount, 2);
    });

    test('an UNPARSEABLE rank falls back to "in rhythm", never to overdue', () {
      // Reading a rank the app cannot parse as 0 would paint the loudest
      // colour in the list over a parsing accident, and a colour that is
      // always red is one people stop reading.
      final row = SpotOverview.fromRecord(
        overviewRecord(const {'urgency': 'sehr dringend'}),
      );

      expect(row.urgency, SpotUrgency.inRhythm.rank);
      expect(row.level, SpotUrgency.inRhythm);
    });

    test('a rank this build has no name for has no level', () {
      // The number still sorts and pages correctly; only the label is unknown,
      // and the screen must be able to see that rather than mislabel it.
      final row = SpotOverview.fromRecord(overviewRecord(const {'urgency': 9}));

      expect(row.urgency, 9);
      expect(row.level, isNull);
    });

    test('a missing count reads as zero, not as unknown', () {
      // Zero contacts is a real and important reading — it is a handover gap —
      // so the row has to be able to say "no contacts" rather than nothing.
      final row = SpotOverview.fromRecord(
        overviewRecord(const {
          'contact_count': '',
          'primary_contact_count': '',
        }),
      );

      expect(row.contactCount, 0);
      expect(row.primaryContactCount, 0);
    });

    test('an UNSET geoPoint reads as null here too', () {
      final row = SpotOverview.fromRecord(
        overviewRecord(const {
          'geo': {'lon': 0, 'lat': 0},
        }),
      );

      expect(row.geo, isNull);
    });

    test('a closed row keeps its reason and its rank', () {
      final row = SpotOverview.fromRecord(
        overviewRecord(const {
          'phase': 'closed',
          'closed_reason': 'netted',
          'next_due_at': '',
          'urgency': 7,
        }),
      );

      expect(row.phase, SpotPhase.closed);
      expect(row.closedReason, ClosedReason.netted);
      expect(row.nextDueAt, isNull);
      expect(row.level, SpotUrgency.closed);
    });
  });

  group('SpotUrgency', () {
    // Written against `values.length` rather than a literal range, because
    // the literal is what had to be edited when `needsSurvey` went in at 4
    // (eiermann-m0r) — and an edit is not the same as a check. This asserts
    // the property the ladder actually has: the ranks are 0..n-1 with no gap
    // and no repeat, which is what lets `fromRank` be a lookup and lets the
    // view SORT on the number.
    test('the ranks are a gapless run from zero, in declaration order', () {
      expect(
        [
          for (var rank = 0; rank < SpotUrgency.values.length; rank++)
            SpotUrgency.fromRank(rank),
        ],
        SpotUrgency.values,
      );
    });

    test('an unknown rank has none', () {
      expect(SpotUrgency.fromRank(SpotUrgency.values.length), isNull);
      expect(SpotUrgency.fromRank(-1), isNull);
      expect(SpotUrgency.fromRank(null), isNull);
    });

    // The wire contract, spelled out. These integers are in `spot_overview`'s
    // CASE, in the server-side sort the keyset paging rides on, and in
    // `/spots?urgency=N` links readers keep — so changing one is a `feat!:`,
    // and a test that only checked the shape above would let it happen quietly.
    test('the rungs sit on the numbers the server and the URLs use', () {
      expect(
        {for (final level in SpotUrgency.values) level.name: level.rank},
        {
          'overdue': 0,
          'dueToday': 1,
          'dueSoon': 2,
          'inRhythm': 3,
          'needsSurvey': 4,
          'prospect': 5,
          'paused': 6,
          'closed': 7,
        },
      );
    });
  });
}
