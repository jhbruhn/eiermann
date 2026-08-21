import 'package:eiermann_models/src/enums.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

part 'visit.freezed.dart';

/// A recorded **Besuch** — one trip to one building, as it was stored.
///
/// The read side of what `VisitDraft` writes, and a separate type on purpose.
/// A draft is what somebody is still filling in and can be sent; this is a
/// fact with an id that nothing but the endpoint could have produced. Folding
/// them into one model would give the sendable shape a nullable id and invite a
/// screen to "save" a row that already exists.
///
/// [tourRun] is the only link between a round and the work done on it. There is
/// no per-stop progress record: every state such a row could hold is already a
/// visit — checked, skipped with a reason, or made on a building the template
/// did not list — so progress is derived from these rows (see `tourProgress`).
///
/// A [VisitOutcome.skipped] visit documents a NON-EVENT: nobody there, no key,
/// scaffolding. It deliberately does not enter the Rhythmus, and it is not an
/// error path either — on a round, skipping with a reason and adding a building
/// are equal-rank actions.
@freezed
abstract class Visit with _$Visit {
  const factory Visit({
    required String id,
    required String spot,
    VisitOutcome? outcome,
    DateTime? visitedAt,
    SkipReason? skipReason,
    String? skipNote,
    String? note,
    String? tourRun,
    String? org,

    /// Who recorded it, as a NAME. The relation may be empty — a closed account
    /// must not take the visits it made with it — so the snapshot is what a
    /// history can actually show.
    String? authorName,

    /// The building's name, from `expand=spot`.
    String? spotName,
    DateTime? created,
  }) = _Visit;

  factory Visit.fromRecord(RecordModel r) => Visit(
    id: r.id,
    spot: pbString(r.data['spot']) ?? '',
    // Null for an outcome this build has no name for, which reads as "newer
    // than this app" rather than as one of the two it does know.
    outcome: VisitOutcome.fromWire(r.data['outcome']),
    visitedAt: pbDate(r.data['visited_at']),
    skipReason: SkipReason.fromWire(r.data['skip_reason']),
    skipNote: pbString(r.data['skip_note']),
    note: pbString(r.data['note']),
    tourRun: pbString(r.data['tour_run']),
    org: pbString(r.data['org']),
    authorName: pbString(r.data['author_name']),
    spotName: pbString(r.get<Object?>('expand.spot.name')),
    created: pbDate(r.data['created']),
  );
}
