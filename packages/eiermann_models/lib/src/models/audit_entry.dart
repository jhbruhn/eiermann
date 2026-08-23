import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

part 'audit_entry.freezed.dart';

/// One recorded act: who changed what, and what it used to say.
///
/// **Every text field here is a SNAPSHOT taken when the act happened**, and
/// that is the whole design rather than a denormalisation for speed. The target
/// may be renamed — and then a live lookup makes the row describe the past
/// wrongly, saying somebody closed "Bahnhofstraße 12" when what they closed was
/// called something else that day. Or the target may be DELETED, which for a
/// Spot is exactly the act most worth recording.
///
/// So [target] is a plain id string and not a relation, and [targetLabel] sits
/// beside it. An id in an audit row with no label next to it is a bug.
///
/// [action], [field], [fromValue] and [toValue] are WIRE values — `closed`,
/// `coordinator`, `7`. A hook never sends user-facing text, because the server
/// does not know which language the reader speaks and these rows outlive any
/// sentence written into them. The client owns every word; `audit_labels.dart`
/// is where they live, and a guard test fails on any registry entry that has
/// none.
@freezed
abstract class AuditEntry with _$AuditEntry {
  const factory AuditEntry({
    required String id,
    required String action,
    required String actorLabel,
    DateTime? createdAt,
    String? actor,
    String? targetType,
    String? target,
    String? targetLabel,
    String? field,
    String? fromValue,
    String? toValue,
    String? detail,
  }) = _AuditEntry;

  factory AuditEntry.fromRecord(RecordModel r) => AuditEntry(
    id: r.id,
    action: pbString(r.data['action']) ?? '',
    // Never empty in practice — the server writes `system` when it has no
    // account to name — but defaulted rather than nullable so no screen has to
    // decide what a blank author means.
    actorLabel: pbString(r.data['actor_label']) ?? '',
    actor: pbString(r.data['actor']),
    targetType: pbString(r.data['target_type']),
    target: pbString(r.data['target']),
    targetLabel: pbString(r.data['target_label']),
    field: pbString(r.data['field']),
    fromValue: pbString(r.data['from_value']),
    toValue: pbString(r.data['to_value']),
    detail: pbString(r.data['detail']),
    createdAt: pbDate(r.data['created']),
  );

  const AuditEntry._();

  /// Whether this row records a value CHANGING, as opposed to an act with no
  /// before-and-after — a deletion, an export.
  bool get isChange => (field ?? '').isNotEmpty;

  /// Whether there was no previous value, as distinct from an empty one.
  ///
  /// An invite has no `from`: the account did not exist a moment ago. The
  /// screen says so instead of rendering an empty side of an arrow.
  bool get hasNoPrevious => (fromValue ?? '').isEmpty;
}
