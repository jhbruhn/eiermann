import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

RecordModel _record(Map<String, dynamic> data) =>
    RecordModel.fromJson({'id': 'e1', ...data});

void main() {
  group('NestEgg', () {
    test('reads a stored egg', () {
      final egg = NestEgg.fromRecord(
        _record({
          'nest': 'n1',
          'org': 'o1',
          'slot_index': 0,
          'kind': 'dummy',
          'since': '2026-08-01 09:00:00.000Z',
          'source_check': 'c1',
        }),
      );

      expect(egg.kind, EggKind.dummy);
      // Zero is a real slot — the first one — so this is `pbInt`, never
      // `pbCount`.
      expect(egg.slotIndex, 0);
      expect(egg.since, isNotNull);
    });

    test('a kind this build cannot read stays null', () {
      // Counted as neither real nor dummy: as a dummy it would tell somebody to
      // pack one fewer Attrappe, as real it would send them out for a swap that
      // is not due.
      final egg = NestEgg.fromRecord(_record({'nest': 'n1', 'kind': 'quail'}));

      expect(egg.kind, isNull);
    });

    test('the age is whole LOCAL days, and null for no date', () {
      // Local and truncated to dates: PocketBase stores UTC, so an egg recorded
      // at 23:30 CET sits on the previous UTC day and a raw subtraction reports
      // a day too many for half of every evening.
      final now = DateTime(2026, 8, 21, 8);
      final egg = NestEgg.fromRecord(
        _record({
          'nest': 'n1',
          'kind': 'real',
          'since': DateTime(2026, 8, 9, 22, 30).toUtc().toIso8601String(),
        }),
      );

      expect(egg.ageInDays(now), 12);
      expect(
        NestEgg.fromRecord(_record({'nest': 'n1'})).ageInDays(now),
        isNull,
      );
    });
  });
}
