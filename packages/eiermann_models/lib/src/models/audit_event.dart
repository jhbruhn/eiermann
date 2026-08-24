import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

part 'audit_event.freezed.dart';

/// One field that moved, inside an [AuditEvent].
///
/// The same shape for all three verbs, which is what lets one renderer handle
/// them with no new strings: a create arrives with only [to] ("set to X"), a
/// delete with only [from] ("cleared, was X"), an update with both.
///
/// [redacted] is the log keeping the FACT of a change while dropping the value
/// — a caretaker's phone number, a password, prose somebody can still correct.
/// It is never the same as an empty value, and a screen that renders it as one
/// tells the reader nothing happened.
@freezed
abstract class AuditChange with _$AuditChange {
  const factory AuditChange({
    required String field,
    String? from,
    String? to,

    /// What the target of a relation-valued field was CALLED when the row was
    /// written. An id in an audit row with no label beside it is a bug: the
    /// target may since have been renamed or deleted, and a live lookup would
    /// make the row describe the past wrongly.
    String? fromLabel,
    String? toLabel,

    /// The value is withheld on purpose. See the class doc.
    @Default(false) bool redacted,

    /// The stored value was cut to fit. Said out loud rather than left as a
    /// silently shortened quote in a document people cite.
    @Default(false) bool truncated,
  }) = _AuditChange;

  /// Named `fromStored` and not `fromJson`: this package runs freezed WITHOUT
  /// json_serializable, and freezed reads the name `fromJson` and emits a call
  /// to `_$AuditChangeFromJson` that nothing generates. The failure is a
  /// missing symbol in generated code that says nothing about the naming rule.
  factory AuditChange.fromStored(Map<String, dynamic> json) => AuditChange(
    field: (json['field'] ?? '').toString(),
    from: json['from']?.toString(),
    to: json['to']?.toString(),
    fromLabel: json['from_label']?.toString(),
    toLabel: json['to_label']?.toString(),
    redacted: json['redacted'] == true,
    truncated: json['truncated'] == true,
  );

  const AuditChange._();

  /// Whether there was no previous value, as distinct from an empty one.
  ///
  /// An invitation has no `from`: the account did not exist a moment ago. The
  /// screen says so instead of rendering an empty side of an arrow, which reads
  /// as a value that was blanked.
  bool get hasNoPrevious => (from ?? '').isEmpty;
}

/// One recorded act: who did what, to which record, and what it used to say.
///
/// **Every text field here is a SNAPSHOT taken when the act happened**, and
/// that is the design rather than a denormalisation for speed. The subject may
/// be renamed — and then a live lookup makes the row describe the past wrongly,
/// saying somebody closed "Bahnhofstraße 12" when what they closed was called
/// something else that day. Or it may be DELETED, which for a Spot is exactly
/// the act most worth recording.
///
/// So [subjectId] and [actorId] are plain id strings and not relations, with
/// their labels beside them. Nothing in this table cascades.
///
/// [action], [severity], [actorKind] and every value inside [changes] are WIRE
/// values — `spot.phase_changed`, `closed`, `coordinator`, `7`. A hook never
/// sends user-facing text, because the server does not know which language the
/// reader speaks and these rows outlive any sentence written into them. The
/// client owns every word; `audit_labels.dart` is where they live, and a guard
/// test fails on any registry entry that has none.
@freezed
abstract class AuditEvent with _$AuditEvent {
  const factory AuditEvent({
    required String id,
    required String action,
    required String actorLabel,
    DateTime? createdAt,
    String? actorId,
    String? actorRole,

    /// `user`, `system`, `cron` or `superuser`. The cron path has no caller at
    /// all — a Spot leaving a pause was decided by a schedule, and a row that
    /// could not say so would implicate whoever looks like the last actor.
    String? actorKind,
    String? subjectCollection,
    String? subjectId,
    String? subjectLabel,

    /// The building this act belongs to, which is how the log is narrowed.
    /// Empty for the acts that belong to no Spot: an account, a tour, the
    /// organisation's own numbers.
    String? spotId,
    String? spotLabel,
    @Default(<AuditChange>[]) List<AuditChange> changes,

    /// The action-specific payload — a Besuch's counts, an export's format.
    /// Deliberately untyped: it differs per action, and a screen renders only
    /// the keys it recognises.
    @Default(<String, dynamic>{}) Map<String, dynamic> detail,

    /// Other ids the row touched, `{nest, visit, area, tour, author}`.
    @Default(<String, dynamic>{}) Map<String, dynamic> refs,

    /// `info`, `notice` or `security`. Lets the coordination lift membership
    /// and sign-in events out of the day-to-day noise of Besuche.
    String? severity,

    /// Correlates the rows of one request. A Besuch is one route and several
    /// records; they share this.
    String? requestId,
  }) = _AuditEvent;

  factory AuditEvent.fromRecord(RecordModel r) => AuditEvent(
    id: r.id,
    action: pbString(r.data['action']) ?? '',
    // Never empty in practice — the server names the actor or writes a kind —
    // but defaulted rather than nullable so no screen has to decide what a
    // blank author means.
    actorLabel: pbString(r.data['actor_label']) ?? '',
    actorId: pbString(r.data['actor_id']),
    actorRole: pbString(r.data['actor_role']),
    actorKind: pbString(r.data['actor_kind']),
    subjectCollection: pbString(r.data['subject_collection']),
    subjectId: pbString(r.data['subject_id']),
    subjectLabel: pbString(r.data['subject_label']),
    spotId: pbString(r.data['spot_id']),
    spotLabel: pbString(r.data['spot_label']),
    changes: _changesOf(r.data['changes']),
    detail: _mapOf(r.data['detail']),
    refs: _mapOf(r.data['refs']),
    severity: pbString(r.data['severity']),
    requestId: pbString(r.data['request_id']),
    createdAt: pbDate(r.data['created']),
  );

  const AuditEvent._();

  /// Whether this row records values CHANGING, as opposed to an act with no
  /// before-and-after — a deletion, an export, a sign-in.
  bool get isChange => changes.isNotEmpty;
}

/// A JSON column arrives as whatever the SDK decoded it to, or as null when the
/// server left it unset. Both are normal, and neither is an error worth
/// surfacing on a screen whose job is to be readable.
List<AuditChange> _changesOf(Object? raw) {
  if (raw is! List) return const <AuditChange>[];
  return raw
      .whereType<Map<dynamic, dynamic>>()
      .map((e) => AuditChange.fromStored(Map<String, dynamic>.from(e)))
      .where((c) => c.field.isNotEmpty)
      .toList(growable: false);
}

Map<String, dynamic> _mapOf(Object? raw) {
  if (raw is! Map) return const <String, dynamic>{};
  return Map<String, dynamic>.from(raw);
}
