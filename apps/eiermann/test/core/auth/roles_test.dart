import 'package:eiermann/core/auth/roles.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RolePermissions', () {
    test('everybody does the field work', () {
      // Two roles, not four: this is a small team where the coordinator also
      // walks tours. A read-only role would be a person who does not exist
      // here.
      for (final role in UserRole.values) {
        expect(role.canRecordFieldwork, isTrue, reason: role.wire);
      }
    });

    test('only the coordination does the things that are hard to undo', () {
      expect(UserRole.member.canDelete, isFalse);
      expect(UserRole.member.canOverrideRhythm, isFalse);
      expect(UserRole.member.canUnprotect, isFalse);
      expect(UserRole.member.canAdminister, isFalse);

      expect(UserRole.coordinator.canDelete, isTrue);
      expect(UserRole.coordinator.canOverrideRhythm, isTrue);
      expect(UserRole.coordinator.canUnprotect, isTrue);
      expect(UserRole.coordinator.canAdminister, isTrue);
    });

    test('the way INTO protected is open to everyone', () {
      // Asserted as the absence of a permission: seeing a protected species and
      // saying so must never be gated. Only the way OUT is the coordinator's,
      // because it re-enables egg removal — the one action here that can be
      // illegal.
      expect(UserRole.member.canUnprotect, isFalse);
      expect(UserRole.member.canRecordFieldwork, isTrue);
    });
  });

  group('the wire values are frozen', () {
    test('a rename of the Dart identifier cannot change the database', () {
      // These strings are in the access rules, in every stored row and in the
      // audit log. They are the contract.
      expect(UserRole.member.wire, 'member');
      expect(UserRole.coordinator.wire, 'coordinator');
      expect(UserRole.fromWire('coordinator'), UserRole.coordinator);
    });

    test('an unknown role reads as null, not as a guess', () {
      // A role this build does not know about is one unreadable field, not a
      // crash and not an accidental promotion.
      expect(UserRole.fromWire('supervisor'), isNull);
      expect(UserRole.fromWire(''), isNull);
      expect(UserRole.fromWire(null), isNull);
    });
  });
}
