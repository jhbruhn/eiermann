import 'package:eiermann_models/src/enums.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'finding_draft.freezed.dart';

/// One Fund, held in memory until the visit is finished.
///
/// Like a `NestCheckDraft`, this records nothing yet: `findings` has no create
/// rule at all, and the only writer is `POST /api/eiermann/visit`. A finding
/// belongs to the visit that found it — that is what a Fund IS, an observation
/// made by somebody who was there — so it travels in the same body, in the same
/// transaction, under the same Idempotency-Key.
///
/// [nest] is optional, and the option is the point: a dead bird on the floor of
/// a stairwell belongs to no nest, and forcing one would make the record claim
/// something nobody saw. When it IS about a nest, the endpoint refuses a nest
/// this visit did not check unless it belongs to the same Spot — an observation
/// attached to a nest nobody looked at is worse than no observation.
@freezed
abstract class FindingDraft with _$FindingDraft {
  const factory FindingDraft({
    required FindingKind kind,

    /// How many. One by default, because that is what a Fund usually is, and a
    /// required count would make "eine tote Taube" a number somebody has to
    /// type.
    @Default(1) int count,

    /// The species, in the words of the person standing in front of it.
    ///
    /// Free text, never a picker over a curated list. The app does not identify
    /// species — it asks — and what has already been typed comes back as
    /// suggestions from the `species_labels` view, which is a record of use
    /// rather than a taxonomy somebody has to maintain.
    String? speciesLabel,
    String? note,

    /// The nest this is about, or null for a finding about the building.
    String? nest,

    /// The nest's label, for this flow's own lines. Never sent — the server has
    /// the nest and reads its own label.
    ///
    /// Here because an id with no label next to it is a bug in this app, and
    /// while the visit is in memory there is nothing to look one up in.
    String? nestLabel,
  }) = _FindingDraft;
}

/// What the flow reads off a finding, and what it sends.
extension FindingDraftBody on FindingDraft {
  /// Whether this is the kind that can end with a Spot being closed.
  ///
  /// Netting, spikes, a blocked access, scaffolding: the building changed in a
  /// way that takes it out of the method's reach. The flow offers the closing
  /// as a FOLLOW-UP rather than doing it — see `eiermann-3is.4`. A structural
  /// change is a fact about the building; closing the Spot is a decision about
  /// the programme, and the second does not follow from the first without
  /// somebody saying so.
  bool get suggestsClosing => kind == FindingKind.siteChange;

  /// One entry of the visit body's `findings` array.
  ///
  /// `count` always goes out, even at its default: the hook reads
  /// `Number(payload.count || 1)`, so an absent count is the same 1 — but a
  /// body that states it is one a person can read in a log without knowing the
  /// hook's default.
  Map<String, dynamic> toBody() => {
    'kind': kind.wire,
    'count': count,
    'nest': ?nest,
    if (speciesLabel case final label? when label.isNotEmpty)
      'species_label': label,
    if (note case final text? when text.isNotEmpty) 'note': text,
  };
}
