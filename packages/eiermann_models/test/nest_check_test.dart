import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

RecordModel checkRecord(Map<String, dynamic> overrides) => RecordModel({
  'id': 'c1',
  'collectionName': 'nest_checks',
  'org': 'org00000default',
  'visit': 'v1',
  'nest': 'n1',
  'state': 'partial',
  'real_before': 2,
  'dummy_before': 0,
  'real_after': 1,
  'dummy_after': 1,
  'removed_real': 1,
  'added_dummy': 1,
  'note': 'zweites Ei noch nicht gelegt',
  'author_name': 'Kaya',
  'checked_at': '2026-08-19 09:00:00.000Z',
  'expand': {
    'nest': {'id': 'n1', 'label': 'N2'},
  },
  ...overrides,
});

void main() {
  group('NestCheck.fromRecord', () {
    test('reads the numbers the check recorded', () {
      final row = NestCheck.fromRecord(checkRecord(const {}));

      expect(row.state, CheckState.partial);
      expect(row.realBefore, 2);
      expect(row.removedReal, 1);
      expect(row.addedDummy, 1);
      expect(row.realAfter, 1);
      expect(row.nestLabel, 'N2');
      expect(row.authorName, 'Kaya');
    });

    test('an empty nest reads as ZERO, not as "nothing recorded"', () {
      // `pbInt` and never `pbCount` here: "no eggs" and "nothing recorded" are
      // the same fact about a count of eggs, and a null would make a chronology
      // print a dash where the answer is none.
      final row = NestCheck.fromRecord(
        checkRecord(const {
          'state': 'empty',
          'real_before': 0,
          'dummy_before': 0,
          'real_after': 0,
          'dummy_after': 0,
          'removed_real': 0,
          'added_dummy': 0,
        }),
      );

      expect(row.realBefore, 0);
      expect(row.removedReal, 0);
    });

    test('a state this build has no name for reads as null', () {
      final row = NestCheck.fromRecord(
        checkRecord(const {'state': 'brooding'}),
      );

      expect(row.state, isNull);
    });
  });
}
