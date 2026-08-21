import 'package:eiermann_models/src/enums.dart';
import 'package:eiermann_models/src/models/nest_check_draft.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

part 'visit_draft.freezed.dart';

/// A whole Besuch, held in memory until somebody finishes it.
///
/// The app is online-only, and this is the mitigation rather than an exception
/// to it: the form collects everything and writes ONCE, so in a cellar with no
/// signal exactly one call fails, at a named point, with a retry that is safe
/// to press three times. It survives losing reception; it does not survive the
/// app being killed, and that is a stated limit.
///
/// A [VisitOutcome.skipped] visit carries a [skipReason] and NO checks. It
/// documents a non-event — nobody there, no key — and the rhythm must not move
/// for it: an empty nest somebody saw and a nest nobody reached are different
/// facts, and only one of them stretches the interval.
@freezed
abstract class VisitDraft with _$VisitDraft {
  const factory VisitDraft({
    required String spot,
    required VisitOutcome outcome,

    /// When the visit happened. Null means "now", filled in by the server so
    /// the timestamp comes from one clock rather than from a phone's.
    DateTime? visitedAt,
    String? note,
    SkipReason? skipReason,
    String? skipNote,
    @Default(<NestCheckDraft>[]) List<NestCheckDraft> checks,
  }) = _VisitDraft;
}

/// What the flow needs to know about a draft, and what it sends.
extension VisitDraftBody on VisitDraft {
  /// The checks that will create a Nachkontrolle.
  List<NestCheckDraft> get halfClutches =>
      checks.where((check) => check.isHalfClutch).toList();

  /// Real eggs this visit takes out of the building — the programme's metric.
  int get removedReal =>
      checks.fold(0, (sum, check) => sum + check.removedReal);

  /// Dummies this visit places, which is what somebody packs the car by.
  int get addedDummy => checks.fold(0, (sum, check) => sum + check.addedDummy);

  /// Whether this draft is one the endpoint could accept.
  ///
  /// Checked here so the flow can keep its finish button disabled instead of
  /// collecting a refusal: a skip with no reason is the same failure as a pause
  /// with none — the record cannot say whether anybody tried.
  bool get isSendable => switch (outcome) {
    VisitOutcome.skipped => skipReason != null && checks.isEmpty,
    VisitOutcome.checked => checks.every((check) => check.isCoherent),
  };

  /// The request body of `POST /api/eiermann/visit`.
  ///
  /// One body, one transaction, one Idempotency-Key. `findings` is absent until
  /// Phase 06 builds the Funde form; the endpoint already reads it.
  Map<String, dynamic> toBody() => {
    'spot': spot,
    'outcome': outcome.wire,
    if (visitedAt case final at?) 'visited_at': at.toUtc().toIso8601String(),
    if (note case final text? when text.isNotEmpty) 'note': text,
    if (outcome == VisitOutcome.skipped) ...{
      if (skipReason case final reason?) 'skip_reason': reason.wire,
      if (skipNote case final text? when text.isNotEmpty) 'skip_note': text,
    },
    'checks': [for (final check in checks) check.toBody()],
  };
}

/// What the endpoint answers: the ids it wrote, and the state it decided on.
///
/// The states matter to the client because the server has the last word on the
/// Halbgelege — [NestCheckDraftMath.effectiveState] predicts it, and this is
/// the confirmation. A replay of the same Idempotency-Key returns this same
/// object rather than writing a second visit.
@freezed
abstract class VisitResult with _$VisitResult {
  const factory VisitResult({
    required String visit,
    @Default(<VisitCheckResult>[]) List<VisitCheckResult> checks,
  }) = _VisitResult;

  /// Reads the endpoint's answer.
  ///
  /// NOT named `fromJson`: freezed treats that name as a request to generate a
  /// json_serializable pair, and this package runs freezed only — the failure
  /// is a missing `_$VisitResultFromJson` in generated code, which reads as a
  /// broken build rather than as a naming rule. The name is also more honest:
  /// this parses one route's response, not a serialised model.
  factory VisitResult.fromResponse(Map<String, dynamic> json) => VisitResult(
    visit: pbString(json['visit']) ?? '',
    // Pattern-matched rather than cast: a `checks` that is not a list at all
    // must read as "no checks reported", not throw a TypeError out of a
    // repository whose callers are catching RepositoryException.
    checks: [
      if (json['checks'] case final List<Object?> raw)
        for (final entry in raw)
          if (entry is Map<String, dynamic>)
            VisitCheckResult.fromResponse(entry),
    ],
  );
}

/// One written check, as the endpoint reports it back.
@freezed
abstract class VisitCheckResult with _$VisitCheckResult {
  const factory VisitCheckResult({
    required String id,
    required String nest,
    CheckState? state,
  }) = _VisitCheckResult;

  /// Reads one entry of the endpoint's `checks` array. See
  /// [VisitResult.fromResponse] for why this is not called `fromJson`.
  factory VisitCheckResult.fromResponse(Map<String, dynamic> json) =>
      VisitCheckResult(
        id: pbString(json['id']) ?? '',
        nest: pbString(json['nest']) ?? '',
        // Null for a state this build has no name for — which reads as "the
        // server decided something newer than this app knows", not as one of
        // the states it does know.
        state: CheckState.fromWire(json['state']),
      );
}

/// What the result says about the Nachkontrollen.
extension VisitResultReading on VisitResult {
  /// The checks the server stored as a Halbgelege. Each one created a
  /// Nachkontrolle.
  List<VisitCheckResult> get halfClutches =>
      checks.where((check) => check.state == CheckState.partial).toList();
}
