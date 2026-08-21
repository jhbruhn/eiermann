import 'package:eiermann_models/src/enums.dart';
import 'package:eiermann_models/src/models/spot.dart';

/// Which phase may follow which — the client's copy of `ALLOWED` in
/// `backend/pocketbase/pb_hooks/app_spot_phase.js`.
///
/// A second copy of a rule the server owns, which is normally the thing to
/// avoid. It exists because the alternative is worse: the phase control has to
/// offer a set of moves, and a control that offers a move the server refuses is
/// a button whose only function is to produce an error message. The server
/// stays the authority — it re-checks every one of these and names the legal
/// moves in its refusal — and this only decides what to draw.
///
/// The two are pinned together by a guard test that parses the hook
/// (`test/spot_transitions_test.dart`), so they cannot drift in silence. The
/// three clauses that go with the graph — a pause needs a reason, a closing
/// needs a reason, activating an Erkundung needs its yes — are NOT duplicated
/// here: see [SpotPhaseMoves], which asks about this Spot rather than restating
/// the rule.
///
/// Three absences are the hook's, quoted because a reader of the client will
/// wonder:
///
///   * `prospect -> paused`. There is nothing to pause: an Erkundung either
///     continues or ends.
///   * anything `-> prospect`. Permission, once obtained, is not un-learned.
///     Losing it is a closing with [ClosedReason.permissionWithdrawn], which
///     keeps the history.
///   * `closed -> paused`. Reopening means somebody is going back, so it lands
///     in [SpotPhase.active] and can be paused from there.
const spotPhaseTransitions = <SpotPhase, List<SpotPhase>>{
  SpotPhase.prospect: [SpotPhase.active, SpotPhase.closed],
  SpotPhase.active: [SpotPhase.paused, SpotPhase.closed],
  SpotPhase.paused: [SpotPhase.active, SpotPhase.closed],
  SpotPhase.closed: [SpotPhase.active],
};

extension SpotPhaseTransitions on SpotPhase {
  /// The phases a Spot in this one may move to, in the order they should be
  /// offered.
  List<SpotPhase> get allowedNext => spotPhaseTransitions[this] ?? const [];
}

/// What one Spot's dossier may offer, and what each move has to collect first.
extension SpotPhaseMoves on Spot {
  /// The moves to offer for this Spot.
  ///
  /// Empty for a phase this build has no name for — a server that gained a
  /// fifth phase. The honest answer there is to offer nothing: the client
  /// cannot know which moves an unknown phase permits, and guessing means
  /// offering a refusal.
  List<SpotPhase> get allowedPhases => phase?.allowedNext ?? const [];

  /// Whether closing this Spot has to name one of the four [ClosedReason]s.
  ///
  /// False for exactly one case, and it is the hook's: a refused Erkundung
  /// closes without one, because the refusal is already recorded in the field
  /// built for it and none of the four values describes an owner who simply
  /// said no.
  bool get closingNeedsReason =>
      !(phase == SpotPhase.prospect && prospectStage == ProspectStage.refused);

  /// Whether activating this Spot also has to record the Zusage.
  ///
  /// The server refuses `prospect -> active` unless [prospectStage] is
  /// [ProspectStage.permitted] — entering a building nobody agreed to is
  /// the one legal risk in this work, so it is gated on the data rather
  /// than on somebody remembering. When it is not set yet, activating is a
  /// statement that permission now exists, and the sheet asks for it
  /// explicitly instead of flipping the field on the way past.
  ///
  /// Only from [SpotPhase.prospect]: reopening a closed Spot is not gated, and
  /// its Erkundung history stays as it was.
  bool get activationRecordsConsent =>
      phase == SpotPhase.prospect && prospectStage != ProspectStage.permitted;
}
