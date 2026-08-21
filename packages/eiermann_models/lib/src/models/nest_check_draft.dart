import 'package:eiermann_models/src/enums.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'nest_check_draft.freezed.dart';

/// What one nest's check will say — held in memory until the visit is finished.
///
/// This is not a record of anything yet. `nest_checks` has no create rule at
/// all: the ONLY writer is `POST /api/eiermann/visit`, which takes the whole
/// Besuch in one body and writes it in one transaction. So the visit flow
/// collects one of these per nest and sends them together. That is what makes a
/// half-finished visit unrepresentable — see `app_visit.js` for the argument.
///
/// The numbers are the reading a person took, in the order they took it:
/// [realBefore] and [dummyBefore] are what was IN THE NEST when they looked —
/// which is not necessarily what the app had stored, because birds lay eggs
/// between visits. [removedReal] and [addedDummy] are what they did about it.
/// Everything else is derived, here and again in the hook.
@freezed
abstract class NestCheckDraft with _$NestCheckDraft {
  const factory NestCheckDraft({
    required String nest,

    /// The nest's label, for the flow's own summary lines.
    ///
    /// Never sent: the server has the nest and reads its own label. It is here
    /// so the review step can say "N3" without a second query while the visit
    /// is still in memory.
    required String nestLabel,
    required CheckState state,
    @Default(0) int realBefore,
    @Default(0) int dummyBefore,
    @Default(0) int removedReal,
    @Default(0) int addedDummy,
    String? note,

    /// The species somebody just identified, when [state] is
    /// [CheckState.protected].
    ///
    /// Reporting a protected bird on a visit IS the determination — the person
    /// is standing in front of it — and the endpoint moves the nest to
    /// `protected` for exactly that reason. The free-text name rides along
    /// because "Dohle" is what the next reader needs; the app never guesses it.
    String? speciesLabel,
  }) = _NestCheckDraft;
}

/// The arithmetic and the wire body.
///
/// Every derivation here has a twin in `app_visit.js`, and the twin is the
/// authority: `checkArithmetic` recomputes the after-counts and REFUSES a body
/// whose own numbers disagree (`visit_eggs_do_not_balance`). That is deliberate
/// — a mismatch means the two sides disagree about what just happened, and
/// silently overwriting would hide a bug in this form. `nest_check_draft_test`
/// pins the two copies together.
extension NestCheckDraftMath on NestCheckDraft {
  /// Whether this check moves eggs, and therefore carries numbers at all.
  ///
  /// The endpoint zeroes every count for any other state, so "3 Kunsteier
  /// unangetastet" is stored as a state, not as a clutch. The clutch itself
  /// stays in `nest_eggs`, untouched.
  bool get touchesEggs =>
      state == CheckState.swapped || state == CheckState.partial;

  /// Real eggs left in the nest afterwards.
  int get realAfter => realBefore - removedReal;

  /// Dummies in the nest afterwards.
  int get dummyAfter => dummyBefore + addedDummy;

  /// Whether the numbers are one somebody could actually have taken.
  ///
  /// Only one way to fail: you cannot remove more real eggs than were there.
  /// The form should never be able to produce it — this exists so the flow can
  /// refuse to send rather than collect a refusal from the server.
  bool get isCoherent => removedReal >= 0 && removedReal <= realBefore;

  /// The state the SERVER will store, which is not always the one requested.
  ///
  /// [CheckState.partial] is not a thing the form claims but a thing the
  /// numbers show: a real egg still in the nest after the work. The endpoint
  /// derives it from the arithmetic and ignores the requested label, because
  /// the Nachkontrolle that keeps a half clutch from hatching unnoticed hangs
  /// off exactly this flag — see `reconcileState` in `app_visit.js`.
  CheckState get effectiveState {
    if (!touchesEggs) return state;
    return realAfter > 0 ? CheckState.partial : CheckState.swapped;
  }

  /// Whether this check will create a Nachkontrolle: the Halbgelege.
  bool get isHalfClutch => effectiveState == CheckState.partial;

  /// One entry of the visit body's `checks` array.
  ///
  /// The after-counts are sent even though the server recomputes them: it
  /// COMPARES them, and a disagreement is a bug worth a 400 rather than a
  /// silent overwrite. The state sent is [effectiveState], so the two sides
  /// agree about the Halbgelege before the answer comes back.
  Map<String, dynamic> toBody() => {
    'nest': nest,
    'state': effectiveState.wire,
    if (touchesEggs) ...{
      'real_before': realBefore,
      'dummy_before': dummyBefore,
      'removed_real': removedReal,
      'added_dummy': addedDummy,
      'real_after': realAfter,
      'dummy_after': dummyAfter,
    },
    if (note case final text? when text.isNotEmpty) 'note': text,
    if (state == CheckState.protected)
      if (speciesLabel case final name? when name.isNotEmpty)
        'species_label': name,
  };
}
