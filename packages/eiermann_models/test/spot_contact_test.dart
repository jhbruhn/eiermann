import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

RecordModel contactRecord(Map<String, dynamic> overrides) => RecordModel({
  'id': 'c1',
  'collectionName': 'spot_contacts',
  'org': 'org00000default',
  'spot': 's1',
  'role': 'caretaker',
  'name': 'Herr Kröger',
  'phone': '0441 123456',
  'email': '',
  'note': '',
  'is_primary': true,
  'created': '2026-08-20 23:43:46.965Z',
  'updated': '2026-08-20 23:43:46.965Z',
  ...overrides,
});

void main() {
  test('SpotContact.fromRecord reads the number somebody has to ring', () {
    final contact = SpotContact.fromRecord(contactRecord(const {}));

    expect(contact.id, 'c1');
    expect(contact.spot, 's1');
    expect(contact.role, ContactRole.caretaker);
    expect(contact.name, 'Herr Kröger');
    expect(contact.phone, '0441 123456');
    expect(contact.email, isNull);
    expect(contact.isPrimary, isTrue);
  });

  test('an unknown role reads as null rather than as "other"', () {
    // "other" is a real choice somebody made; mapping an unknown value onto it
    // would put words in their mouth.
    final contact = SpotContact.fromRecord(
      contactRecord(const {'role': 'housing_cooperative'}),
    );

    expect(contact.role, isNull);
  });

  test('an absent is_primary reads as false', () {
    // The collection does not require the flag, so a row written by an older
    // client can omit it — and "not the first number to try" is the safe read.
    final contact = SpotContact.fromRecord(contactRecord(const {}));
    final withoutFlag = SpotContact.fromRecord(
      RecordModel({'id': 'c2', 'name': 'Frau Mahler', 'role': 'tenant'}),
    );

    expect(contact.isPrimary, isTrue);
    expect(withoutFlag.isPrimary, isFalse);
    expect(withoutFlag.role, ContactRole.tenant);
  });
}
