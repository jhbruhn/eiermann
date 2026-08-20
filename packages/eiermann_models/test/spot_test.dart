import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

RecordModel spotRecord(Map<String, dynamic> overrides) => RecordModel({
  'id': 's1',
  'collectionName': 'spots',
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
  'pause_reason': '',
  'closed_reason': '',
  'closed_at': '',
  'access_note': 'Klingel Hausmeister Kröger',
  'note': '',
  'facade_photo': '',
  'next_due_at': '2026-08-15 00:00:00.000Z',
  'created': '2026-08-20 23:43:46.862Z',
  'updated': '2026-08-20 23:43:46.862Z',
  ...overrides,
});

void main() {
  group('Spot.fromRecord', () {
    test('reads the fields a row and a dossier are built from', () {
      final spot = Spot.fromRecord(spotRecord(const {}));

      expect(spot.id, 's1');
      expect(spot.name, 'Bahnhofstraße 12');
      expect(spot.city, 'Oldenburg');
      expect(spot.phase, SpotPhase.active);
      expect(spot.geoConfirmed, isTrue);
      expect(spot.accessNote, 'Klingel Hausmeister Kröger');
      expect(spot.nextDueAt, DateTime.utc(2026, 8, 15));
    });

    test('an UNSET geoPoint reads as null, not as Null Island', () {
      // PocketBase has no null for a geoPoint: clearing one stores
      // {lon: 0, lat: 0}. Read literally that is a real place several hundred
      // kilometres off Ghana, so an un-pinned Spot would render as a
      // plausible-looking marker in the Atlantic instead of as missing data.
      final spot = Spot.fromRecord(
        spotRecord(const {
          'geo': {'lon': 0, 'lat': 0},
        }),
      );

      expect(spot.geo, isNull);
    });

    test('a pin that really is on the equator survives', () {
      // Only the exact pair is the sentinel — clamping a whole degree would
      // throw away pins somebody set by hand.
      final spot = Spot.fromRecord(
        spotRecord(const {
          'geo': {'lon': 0.0, 'lat': 0.1},
        }),
      );

      expect(spot.geo, const GeoPoint(lon: 0, lat: 0.1));
    });

    test('an UNKNOWN select value reads as null rather than a guess', () {
      // A server that gained a phase this build does not know must cost one
      // unreadable field on one row, never a wrong one: mapping it onto the
      // nearest known value would show a Spot as active that is not.
      final spot = Spot.fromRecord(
        spotRecord(const {
          'phase': 'mothballed',
          'prospect_stage': 'lawyer_involved',
          'closed_reason': 'demolished_by_storm',
        }),
      );

      expect(spot.phase, isNull);
      expect(spot.prospectStage, isNull);
      expect(spot.closedReason, isNull);
    });

    test('an empty select reads as null, and empty text as null', () {
      final spot = Spot.fromRecord(spotRecord(const {}));

      expect(spot.prospectStage, isNull);
      expect(spot.closedReason, isNull);
      expect(spot.note, isNull);
      expect(spot.facadePhoto, isNull);
      expect(spot.closedAt, isNull);
    });

    test('the closed reason is read, because the dossier keeps it', () {
      final spot = Spot.fromRecord(
        spotRecord(const {
          'phase': 'closed',
          'closed_reason': 'netted',
          'closed_at': '2026-07-01 00:00:00.000Z',
        }),
      );

      expect(spot.phase, SpotPhase.closed);
      expect(spot.closedReason, ClosedReason.netted);
      expect(spot.closedAt, DateTime.utc(2026, 7));
    });

    test('the prospect stage stays readable on an ACTIVE Spot', () {
      // It is history, not a transient: how permission was obtained is part of
      // the dossier, and losing it is how the same conversation gets had twice.
      final spot = Spot.fromRecord(
        spotRecord(const {'phase': 'active', 'prospect_stage': 'permitted'}),
      );

      expect(spot.prospectStage, ProspectStage.permitted);
    });
  });

  group('addressLine', () {
    test('joins street and place', () {
      final spot = Spot.fromRecord(spotRecord(const {}));

      expect(spot.addressLine, 'Bahnhofstraße 12, 26122 Oldenburg');
    });

    test('a Spot with no address at all has no line, not a stray comma', () {
      final spot = Spot.fromRecord(
        spotRecord(const {'street': '', 'postal_code': '', 'city': ''}),
      );

      expect(spot.addressLine, isNull);
    });

    test('a partial address drops the missing half', () {
      expect(
        Spot.fromRecord(
          spotRecord(const {'postal_code': '', 'city': ''}),
        ).addressLine,
        'Bahnhofstraße 12',
      );
      expect(
        Spot.fromRecord(
          spotRecord(const {'street': '', 'postal_code': ''}),
        ).addressLine,
        'Oldenburg',
      );
    });
  });
}
