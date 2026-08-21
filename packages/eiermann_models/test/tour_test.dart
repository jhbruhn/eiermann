import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

void main() {
  group('Tour.fromRecord', () {
    test('reads the template', () {
      final tour = Tour.fromRecord(
        RecordModel({
          'id': 't1',
          'name': 'Tour 1',
          'is_active': true,
          'note': 'Donnerstags',
          'sort_index': 2,
          'org': 'org1',
        }),
      );

      expect(tour.name, 'Tour 1');
      expect(tour.isActive, isTrue);
      expect(tour.note, 'Donnerstags');
      expect(tour.sortIndex, 2);
    });

    test('a retired template reads as retired', () {
      final tour = Tour.fromRecord(
        RecordModel({'id': 't1', 'name': 'Alt', 'is_active': false}),
      );

      expect(tour.isActive, isFalse);
    });
  });

  group('TourStop.fromRecord', () {
    test('takes the building name from the expand', () {
      // An id with no label next to it is a bug in this app: a stop showing an
      // id is a row nobody can read.
      final stop = TourStop.fromRecord(
        RecordModel({
          'id': 'st1',
          'tour': 't1',
          'spot': 's1',
          'sort_index': 0,
          'expand': {
            'spot': {'id': 's1', 'name': 'Bahnhofstraße 12'},
          },
        }),
      );

      expect(stop.spotName, 'Bahnhofstraße 12');
      expect(stop.spot, 's1');
    });

    test('an un-expanded stop has no name rather than the id', () {
      final stop = TourStop.fromRecord(
        RecordModel({'id': 'st1', 'tour': 't1', 'spot': 's1'}),
      );

      expect(stop.spotName, isNull);
    });
  });

  group('TourRun.fromRecord', () {
    test('reads a round walked on a template', () {
      final run = TourRun.fromRecord(
        RecordModel({
          'id': 'r1',
          'tour': 't1',
          'tour_name': 'Tour 1',
          'started_by': 'u1',
          'started_by_name': 'Anke',
          'started_at': '2026-08-21 07:30:00.000Z',
        }),
      );

      expect(run.tour, 't1');
      expect(run.tourName, 'Tour 1');
      expect(run.startedByName, 'Anke');
      expect(run.startedAt, DateTime.utc(2026, 8, 21, 7, 30));
      expect(run.isOpen, isTrue);
      expect(run.isAdHoc, isFalse);
    });

    test('a missing finished_at is what OPEN means', () {
      // PocketBase stores a never-set date as the empty string, so the whole
      // open/closed state is this field being empty. There is no second flag to
      // fall out of step with it.
      final run = TourRun.fromRecord(
        RecordModel({'id': 'r1', 'finished_at': ''}),
      );

      expect(run.finishedAt, isNull);
      expect(run.isOpen, isTrue);
    });

    test('a finished round is closed', () {
      final run = TourRun.fromRecord(
        RecordModel({'id': 'r1', 'finished_at': '2026-08-21 12:00:00.000Z'}),
      );

      expect(run.isOpen, isFalse);
    });

    test('no name at all is the improvised round', () {
      final run = TourRun.fromRecord(RecordModel({'id': 'r1'}));

      expect(run.isAdHoc, isTrue);
      expect(run.tour, isNull);
    });

    test('a deleted template leaves the round still named', () {
      // `tour_runs.tour` does not cascade, so the relation goes empty while the
      // round was still a walking of "Tour 1". Reading THAT as improvised would
      // rewrite what happened, which is why `isAdHoc` reads the name and not
      // the relation.
      final run = TourRun.fromRecord(
        RecordModel({'id': 'r1', 'tour': '', 'tour_name': 'Tour 1'}),
      );

      expect(run.tour, isNull);
      expect(run.isAdHoc, isFalse);
      expect(run.tourName, 'Tour 1');
    });
  });

  group('Visit.fromRecord', () {
    test('reads the round it was made on', () {
      final visit = Visit.fromRecord(
        RecordModel({
          'id': 'v1',
          'spot': 's1',
          'outcome': 'checked',
          'tour_run': 'r1',
          'visited_at': '2026-08-21 09:00:00.000Z',
          'author_name': 'Anke',
        }),
      );

      expect(visit.tourRun, 'r1');
      expect(visit.outcome, VisitOutcome.checked);
      expect(visit.authorName, 'Anke');
    });

    test('a visit outside any round has none', () {
      final visit = Visit.fromRecord(
        RecordModel({'id': 'v1', 'spot': 's1', 'tour_run': ''}),
      );

      expect(visit.tourRun, isNull);
    });

    test('a skip carries its reason', () {
      final visit = Visit.fromRecord(
        RecordModel({
          'id': 'v1',
          'spot': 's1',
          'outcome': 'skipped',
          'skip_reason': 'no_key',
        }),
      );

      expect(visit.outcome, VisitOutcome.skipped);
      expect(visit.skipReason, SkipReason.noKey);
    });

    test('an outcome this build has no name for reads as null', () {
      // "Newer than this app", not one of the two it knows.
      final visit = Visit.fromRecord(
        RecordModel({'id': 'v1', 'spot': 's1', 'outcome': 'teleported'}),
      );

      expect(visit.outcome, isNull);
    });
  });
}
