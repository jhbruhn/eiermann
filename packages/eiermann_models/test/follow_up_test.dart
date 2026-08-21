import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

RecordModel _record(Map<String, dynamic> data) =>
    RecordModel.fromJson({'id': 'f1', ...data});

void main() {
  group('FollowUp', () {
    test('reads the Nachkontrolle a Halbgelege created', () {
      final followUp = FollowUp.fromRecord(
        _record({
          'org': 'o1',
          'spot': 's1',
          'nest': 'n3',
          'due_at': '2026-08-25 00:00:00.000Z',
          'reason': 'half_clutch',
          'created_from_check': 'c1',
          'resolved_at': '',
        }),
      );

      expect(followUp.reason, FollowUpReason.halfClutch);
      // A PocketBase date field that was never set stores the empty string, so
      // "open" has to survive that and not only a missing key.
      expect(followUp.resolvedAt, isNull);
      expect(followUp.isOpen, isTrue);
    });

    test('the labels come out of the expand, not as ids', () {
      // The dashboard's top block spans every building, and an id with no label
      // next to it is a bug in this app.
      final followUp = FollowUp.fromRecord(
        _record({
          'spot': 's1',
          'nest': 'n3',
          'expand': {
            'spot': {'id': 's1', 'name': 'Bahnhofstr. 12'},
            'nest': {'id': 'n3', 'label': 'N3'},
          },
        }),
      );

      expect(followUp.spotName, 'Bahnhofstr. 12');
      expect(followUp.nestLabel, 'N3');
    });

    test('a missing expand is no label, not a crash', () {
      // PocketBase omits the key when the expand was not requested OR when the
      // related row is not readable. Both are the same thing to a caller.
      final followUp = FollowUp.fromRecord(_record({'spot': 's1'}));

      expect(followUp.spotName, isNull);
      expect(followUp.nestLabel, isNull);
    });

    test('overdue is decided on LOCAL calendar days', () {
      // A follow-up due today must not read as overdue for the hours after
      // midnight CET during which UTC is still yesterday.
      final due = FollowUp.fromRecord(
        _record({
          'spot': 's1',
          'due_at': DateTime(2026, 8, 21, 12).toUtc().toIso8601String(),
        }),
      );

      expect(due.isOverdue(DateTime(2026, 8, 21, 0, 30)), isFalse);
      expect(due.isOverdue(DateTime(2026, 8, 22, 0, 30)), isTrue);
    });
  });
}
