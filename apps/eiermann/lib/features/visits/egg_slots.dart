import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/foundation.dart';

/// What the volunteer did with one egg they found.
///
/// Three outcomes and not two, because the third one happens in the field: you
/// take the real egg out and have no Attrappe left to put in. The programme's
/// metric is the real eggs REMOVED, so that case must be recordable — and it is
/// a different fact from a swap, since the nest is then genuinely empty and the
/// birds may start over.
enum SlotAction {
  /// Left where it was. The only legal action on a dummy, and on an egg
  /// somebody decided not to touch.
  keep,

  /// A real egg taken out, a dummy put in its place. The job.
  swapped,

  /// A real egg taken out, nothing put back.
  removed,
}

/// One position in the egg row, as the sheet holds it.
///
/// [found] is what was IN THE NEST when somebody looked — which is not
/// necessarily what the app had stored, because birds lay eggs between visits.
/// [since] is the stored date of an egg that was already there, and null for
/// one added in the sheet: a slot that has no date yet must not be drawn as
/// "0 Tage", which would read as "arrived today" rather than "we do not know".
@immutable
class EggSlot {
  const EggSlot({
    required this.found,
    this.action = SlotAction.keep,
    this.since,
  });

  /// A slot seeded from a stored `nest_eggs` row.
  factory EggSlot.stored(NestEgg egg) =>
      EggSlot(found: egg.kind, since: egg.since);

  /// A slot the volunteer added because they found an egg the app did not know
  /// about. The commonest reason a nest is due at all.
  factory EggSlot.added(EggKind kind) => EggSlot(found: kind);

  /// What is in the slot, or null for a stored row whose kind this build cannot
  /// read. Such a slot counts as neither real nor dummy — see [countsAsReal].
  final EggKind? found;

  final SlotAction action;
  final DateTime? since;

  /// Whether this slot is one the arithmetic can count as a real egg.
  bool get countsAsReal => found == EggKind.real;

  /// Whether this slot is one the arithmetic can count as a dummy.
  bool get countsAsDummy => found == EggKind.dummy;

  /// Whether the volunteer took the egg out, with or without replacing it.
  bool get wasRemoved => action != SlotAction.keep;

  /// What is in this slot AFTER the visit, or null when it is empty now.
  ///
  /// The row redraws from this, so the sheet shows the nest as it will be left
  /// — the one thing a volunteer double-checks before climbing down.
  EggKind? get resulting => switch (action) {
    SlotAction.keep => found,
    SlotAction.swapped => EggKind.dummy,
    SlotAction.removed => null,
  };

  /// The next action for a tap on this slot.
  ///
  /// One control, three states, in the order they get used: found, swapped,
  /// removed. Only a real egg cycles — there is nothing to do to a dummy, and a
  /// slot whose kind cannot be read must not be turned into a claim about what
  /// happened to it.
  EggSlot cycled() {
    if (!countsAsReal) return this;
    return EggSlot(
      found: found,
      since: since,
      action: switch (action) {
        SlotAction.keep => SlotAction.swapped,
        SlotAction.swapped => SlotAction.removed,
        SlotAction.removed => SlotAction.keep,
      },
    );
  }

  /// This slot with every real egg swapped — the standard case in one tap.
  EggSlot swappedIfReal() => countsAsReal && action == SlotAction.keep
      ? EggSlot(found: found, since: since, action: SlotAction.swapped)
      : this;
}

/// The check [slots] describe, for the nest named by [nestId].
///
/// **This is the client half of an arithmetic the server owns.**
/// `checkArithmetic` in `app_visit.js` recomputes the after-counts and refuses
/// a body whose own numbers disagree, so the point of deriving them here is not
/// to be believed — it is to show the volunteer the nest as they are leaving
/// it, and to keep the form from being able to produce a refusal at all.
///
/// The STATE is derived rather than chosen, and that is the design:
///
/// * no slots at all means [CheckState.empty] — the only state that stretches
///   the rhythm ladder, so it must come from "nothing was in there" and never
///   from a control somebody tapped by mistake;
/// * anything taken out is a swap, which the server reconciles to
///   [CheckState.partial] when a real egg is still in the nest afterwards;
/// * eggs present and nothing taken out is [CheckState.untouched], which resets
///   the ladder like any other find — the nest is in use.
///
/// A special state ([CheckState.notReachable], [CheckState.gone],
/// [CheckState.protected]) is not derivable from a clutch reading and is
/// passed in as [override]; the slots are then irrelevant and the endpoint
/// zeroes every count.
NestCheckDraft draftFromSlots({
  required String nestId,
  required String nestLabel,
  required List<EggSlot> slots,
  CheckState? override,
  String? note,
  String? speciesLabel,
}) {
  final realBefore = slots.where((slot) => slot.countsAsReal).length;
  final dummyBefore = slots.where((slot) => slot.countsAsDummy).length;
  final removedReal = slots
      .where((slot) => slot.countsAsReal && slot.wasRemoved)
      .length;
  final addedDummy = slots
      .where((slot) => slot.countsAsReal && slot.action == SlotAction.swapped)
      .length;

  final state =
      override ??
      (slots.isEmpty
          ? CheckState.empty
          : removedReal > 0
          ? CheckState.swapped
          : CheckState.untouched);

  return NestCheckDraft(
    nest: nestId,
    nestLabel: nestLabel,
    state: state,
    // Zeroed for a state that does not touch eggs, exactly as the endpoint
    // does: "3 Kunsteier unangetastet" is a state, not a clutch, and the clutch
    // itself stays in `nest_eggs` where it already is.
    realBefore: override == null || _touchesEggs(state) ? realBefore : 0,
    dummyBefore: override == null || _touchesEggs(state) ? dummyBefore : 0,
    removedReal: override == null || _touchesEggs(state) ? removedReal : 0,
    addedDummy: override == null || _touchesEggs(state) ? addedDummy : 0,
    note: note,
    speciesLabel: speciesLabel,
  );
}

bool _touchesEggs(CheckState state) =>
    state == CheckState.swapped || state == CheckState.partial;

/// The states a volunteer picks by hand, as opposed to the ones the clutch
/// reading derives.
///
/// [CheckState.swapped] and [CheckState.partial] are absent because they are
/// facts about the numbers, and [CheckState.empty] because it is what "no eggs
/// in the row" already means. Offering all seven would make the sheet a
/// vocabulary quiz.
const List<CheckState> kSpecialCheckStates = [
  CheckState.notReachable,
  CheckState.gone,
  CheckState.protected,
];

/// The states that stay available on a nest nobody may touch.
///
/// The swap path is not disabled on a protected nest — it is REPLACED by an
/// explanation. What remains is everything a person can honestly record about a
/// nest they are not allowed to reach into: it is still protected, they left it
/// alone, they could not get to it, or it is gone.
const List<CheckState> kProtectedCheckStates = [
  CheckState.protected,
  CheckState.untouched,
  CheckState.notReachable,
  CheckState.gone,
];
