import 'package:eiermann_models/src/enums.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

part 'follow_up.freezed.dart';

/// A Nachkontrolle — a second date on a nest, ahead of the rhythm.
///
/// The [FollowUpReason.halfClutch] one is the answer to the second named field
/// problem: only one egg could be swapped because the other had not been laid
/// yet, so somebody must come back within days. In the WhatsApp history that
/// note died in the thread. Here it is a row with a date, and it enters the
/// Spot's due date as a minimum — which is why it wins: it is earlier than the
/// ladder would have come round.
///
/// [dueAt] is **stored, not derived**. Recomputing it from the org's current
/// `half_clutch_return_days` would move every outstanding follow-up whenever
/// somebody edits that setting — including overdue ones, which would silently
/// become on time. A plan is a fact about a decision somebody made.
///
/// It is resolved by a LATER CHECK on the nest, never by time passing and never
/// by a skipped visit: the whole point is that somebody went back and looked.
/// So the client never writes [resolvedAt] — the collection's update rule
/// refuses it.
@freezed
abstract class FollowUp with _$FollowUp {
  const factory FollowUp({
    required String id,
    required String spot,
    String? org,

    /// The nest this is about. Optional in the schema — a manual follow-up may
    /// be about the building ("check that new lock again") rather than a nest.
    String? nest,
    DateTime? dueAt,
    FollowUpReason? reason,
    String? note,

    /// The building's name, from `expand=spot`.
    ///
    /// Read rather than looked up later, because the dashboard's top block
    /// shows follow-ups from every building at once and an id with no label
    /// next to it is a bug in this app. Null when the expand was not asked for
    /// — or when the related row is not readable, which PocketBase reports by
    /// leaving it out rather than by failing.
    String? spotName,

    /// The nest's label, from `expand=nest`. Same reasoning as [spotName]:
    /// "Nachkontrolle Halbgelege, N3" is what somebody needs before climbing
    /// into an attic with four nests in it.
    String? nestLabel,
    String? createdFromCheck,
    DateTime? resolvedAt,
    String? resolvedByCheck,
    DateTime? created,
    DateTime? updated,
  }) = _FollowUp;

  factory FollowUp.fromRecord(RecordModel r) => FollowUp(
    id: r.id,
    spot: pbString(r.data['spot']) ?? '',
    org: pbString(r.data['org']),
    nest: pbString(r.data['nest']),
    dueAt: pbDate(r.data['due_at']),
    reason: FollowUpReason.fromWire(r.data['reason']),
    note: pbString(r.data['note']),
    spotName: _expandedString(r, 'spot', 'name'),
    nestLabel: _expandedString(r, 'nest', 'label'),
    createdFromCheck: pbString(r.data['created_from_check']),
    resolvedAt: pbDate(r.data['resolved_at']),
    resolvedByCheck: pbString(r.data['resolved_by_check']),
    created: pbDate(r.data['created']),
    updated: pbDate(r.data['updated']),
  );
}

/// [field] of the record expanded under [relation], or null.
///
/// Read through the SDK's key-path getter, which is what handles the shape:
/// PocketBase omits the key entirely when the expand was not requested or the
/// related row is not readable, and both are the same thing to a caller —
/// there is no label to show. The alternative, `record.expand[relation]`, is
/// deprecated and hands back a list even for a single relation.
String? _expandedString(RecordModel r, String relation, String field) =>
    pbString(r.get<Object?>('expand.$relation.$field'));

/// What a due list reads off a follow-up.
extension FollowUpReading on FollowUp {
  /// Whether nobody has been back yet.
  bool get isOpen => resolvedAt == null;

  /// Whether the date has passed, on LOCAL calendar days.
  ///
  /// Local and truncated, like every other date comparison in this app: a
  /// follow-up due today must not read as overdue for the four hours after
  /// midnight CET during which UTC is still yesterday.
  bool isOverdue(DateTime now) {
    final due = dueAt?.toLocal();
    if (due == null) return false;
    final today = DateTime(now.year, now.month, now.day);
    return DateTime(due.year, due.month, due.day).isBefore(today);
  }
}
