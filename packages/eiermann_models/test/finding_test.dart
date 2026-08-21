import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

RecordModel findingRecord(Map<String, dynamic> overrides) => RecordModel({
  'id': 'f1',
  'collectionName': 'findings',
  'org': 'org00000default',
  'spot': 's1',
  'visit': 'v1',
  'nest': 'n1',
  'kind': 'dead_bird',
  'count': 2,
  'species_label': 'Dohle',
  'note': 'unter dem Fenster',
  'photo': '',
  'author_name': 'Kaya',
  'found_at': '2026-08-19 09:00:00.000Z',
  'created': '2026-08-19 09:05:00.000Z',
  'expand': {
    'nest': {'id': 'n1', 'label': 'N1'},
    'spot': {'id': 's1', 'name': 'Bahnhofstraße 12'},
  },
  ...overrides,
});

void main() {
  group('Finding.fromRecord', () {
    test('reads the line a chronology draws', () {
      final row = Finding.fromRecord(findingRecord(const {}));

      expect(row.kind, FindingKind.deadBird);
      expect(row.count, 2);
      expect(row.speciesLabel, 'Dohle');
      expect(row.note, 'unter dem Fenster');
      expect(row.foundAt, isNotNull);
    });

    test('the nest and the building come with a NAME', () {
      // An id with no label next to it is a bug in this app: "Fund an gu3k1..."
      // is unreadable exactly where it matters.
      final row = Finding.fromRecord(findingRecord(const {}));

      expect(row.nestLabel, 'N1');
      expect(row.spotName, 'Bahnhofstraße 12');
    });

    test('the author is a SNAPSHOT, not a relation to look up', () {
      // A closed account must not take the Funde it recorded with it, and a
      // chronology whose author column empties when somebody leaves the group
      // describes the past wrongly.
      expect(Finding.fromRecord(findingRecord(const {})).authorName, 'Kaya');
    });

    test('a kind this build has no name for reads as null', () {
      // Not as the nearest one it knows: a server newer than this app must not
      // make a "Brut" finding show up as a dead bird.
      final row = Finding.fromRecord(
        findingRecord(const {'kind': 'nest_removed'}),
      );

      expect(row.kind, isNull);
    });

    test('a finding about the building carries no nest', () {
      final row = Finding.fromRecord(
        findingRecord(const {'nest': '', 'expand': <String, dynamic>{}}),
      );

      expect(row.nest, isNull);
      expect(row.nestLabel, isNull);
    });
  });
}
