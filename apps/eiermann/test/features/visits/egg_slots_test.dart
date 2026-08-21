import 'package:eiermann/features/visits/egg_slots.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter_test/flutter_test.dart';

NestCheckDraft draftOf(List<EggSlot> slots, {CheckState? override}) =>
    draftFromSlots(
      nestId: 'n1',
      nestLabel: 'N1',
      slots: slots,
      override: override,
    );

void main() {
  group('one slot', () {
    test('a real egg cycles found, swapped, removed and back', () {
      // One control, three states, in the order they get used. The third one is
      // the field case that must stay recordable: you take the egg out and have
      // no Attrappe left.
      var slot = const EggSlot(found: EggKind.real);
      expect(slot.action, SlotAction.keep);
      expect(slot.resulting, EggKind.real);

      slot = slot.cycled();
      expect(slot.action, SlotAction.swapped);
      expect(slot.resulting, EggKind.dummy);

      slot = slot.cycled();
      expect(slot.action, SlotAction.removed);
      expect(slot.resulting, isNull);

      expect(slot.cycled().action, SlotAction.keep);
    });

    test('a dummy does not cycle — there is nothing to do to it', () {
      const slot = EggSlot(found: EggKind.dummy);

      expect(slot.cycled(), same(slot));
    });

    test('an unreadable slot cannot be turned into a claim', () {
      // A stored row whose kind this build cannot read counts as neither real
      // nor dummy, and saying something happened to it would be inventing the
      // one fact nobody has.
      const slot = EggSlot(found: null);

      expect(slot.cycled().action, SlotAction.keep);
      expect(draftOf([slot]).realBefore, 0);
      expect(draftOf([slot]).dummyBefore, 0);
    });
  });

  group('the derived check', () {
    test('an empty row means the nest is empty', () {
      // The one state that stretches the rhythm ladder, and it comes from
      // "nothing was in there" — never from a control somebody tapped.
      expect(draftOf(const []).state, CheckState.empty);
    });

    test('eggs present and nothing taken out is untouched', () {
      // Resets the ladder like any other find: the nest is in use.
      final check = draftOf(const [
        EggSlot(found: EggKind.dummy),
        EggSlot(found: EggKind.real),
      ]);

      expect(check.state, CheckState.untouched);
      expect(check.realBefore, 1);
      expect(check.dummyBefore, 1);
    });

    test('swapping every real egg is a clean swap', () {
      final check = draftOf([
        const EggSlot(found: EggKind.real).cycled(),
        const EggSlot(found: EggKind.real).cycled(),
      ]);

      expect(check.removedReal, 2);
      expect(check.addedDummy, 2);
      expect(check.realAfter, 0);
      expect(check.dummyAfter, 2);
      expect(check.effectiveState, CheckState.swapped);
    });

    test('a real egg left in the nest IS the Halbgelege', () {
      final check = draftOf([
        const EggSlot(found: EggKind.real).cycled(),
        const EggSlot(found: EggKind.real),
      ]);

      expect(check.isHalfClutch, isTrue);
      expect(check.realAfter, 1);
    });

    test('a removal with no Attrappe counts as removed, not as swapped', () {
      // The programme's metric is the real eggs REMOVED. No dummy left in the
      // bag is a different fact from a swap: the nest is then genuinely empty
      // and the birds may start over.
      final check = draftOf([
        const EggSlot(found: EggKind.real).cycled().cycled(),
      ]);

      expect(check.removedReal, 1);
      expect(check.addedDummy, 0);
      expect(check.dummyAfter, 0);
      expect(check.effectiveState, CheckState.swapped);
    });

    test('swapping all at once touches only the untouched real eggs', () {
      final slots = [
        const EggSlot(found: EggKind.real),
        const EggSlot(found: EggKind.real).cycled().cycled(),
        const EggSlot(found: EggKind.dummy),
      ].map((slot) => slot.swappedIfReal()).toList();

      expect(slots[0].action, SlotAction.swapped);
      // Already decided — "alle tauschen" must not overwrite a removal somebody
      // chose deliberately.
      expect(slots[1].action, SlotAction.removed);
      expect(slots[2].action, SlotAction.keep);
    });

    test('a special state overrides the row and zeroes the numbers', () {
      // The endpoint zeroes every count for a state that does not touch eggs,
      // and the clutch itself stays in `nest_eggs` where it already is.
      final check = draftOf(const [
        EggSlot(found: EggKind.dummy),
        EggSlot(found: EggKind.real),
      ], override: CheckState.notReachable);

      expect(check.state, CheckState.notReachable);
      expect(check.realBefore, 0);
      expect(check.dummyBefore, 0);
      expect(check.toBody(), isNot(contains('real_before')));
    });
  });

  group('what the sheet offers', () {
    test('the pickable states exclude the ones the numbers decide', () {
      // Offering all seven would make the sheet a vocabulary quiz — and two of
      // them are facts about the arithmetic, not choices.
      expect(kSpecialCheckStates, isNot(contains(CheckState.swapped)));
      expect(kSpecialCheckStates, isNot(contains(CheckState.partial)));
      expect(kSpecialCheckStates, isNot(contains(CheckState.empty)));
    });

    test('a protected nest keeps every honest option and no swap', () {
      // The swap path is REPLACED by an explanation, not greyed out. What
      // remains is what a person can truthfully record about a nest they may
      // not reach into.
      expect(kProtectedCheckStates, contains(CheckState.protected));
      expect(kProtectedCheckStates, contains(CheckState.untouched));
      expect(kProtectedCheckStates, isNot(contains(CheckState.swapped)));
      expect(kProtectedCheckStates, isNot(contains(CheckState.partial)));
    });
  });
}
