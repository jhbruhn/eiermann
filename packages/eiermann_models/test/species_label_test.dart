import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

void main() {
  group('SpeciesLabel.fromRecord', () {
    test('reads the word and how often it has been used', () {
      final row = SpeciesLabel.fromRecord(
        RecordModel({
          'id': 'org00000default:Dohle',
          'collectionName': 'species_labels',
          'org': 'org00000default',
          'label': 'Dohle',
          'used_count': 7,
        }),
      );

      expect(row.label, 'Dohle');
      expect(row.usedCount, 7);
      expect(row.org, 'org00000default');
      // `org:label`, because a view has no underlying record to point at and
      // two organisations that both wrote "Dohle" are two rows.
      expect(row.id, 'org00000default:Dohle');
    });

    test('a count that arrives as a STRING still reads as a number', () {
      // A computed view column falls back to type `json`, so anything but a
      // bare integer expression crosses the wire quoted. `used_count` is a
      // plain `COUNT(*)` today and arrives as a number — this pins the client
      // against the day somebody wraps it in an expression, because the
      // alternative failure is a picker silently ordered by text.
      final row = SpeciesLabel.fromRecord(
        RecordModel({'id': 'o:D', 'label': 'Dohle', 'used_count': '7'}),
      );

      expect(row.usedCount, 7);
    });

    test('a missing count reads as zero rather than throwing', () {
      final row = SpeciesLabel.fromRecord(
        RecordModel({'id': 'o:D', 'label': 'Dohle'}),
      );

      expect(row.usedCount, 0);
    });
  });
}
