import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

part 'tour.freezed.dart';

/// A **Tour** — the reusable template: a name the whole group says out loud
/// ("Tour 1") and, through [TourStop], an ordered list of buildings.
///
/// The template is what makes the handover survivable. Whoever walks a route
/// for the first time reads the same list, in the same order, as the person who
/// has walked it for years — which is the answer to "die Übergabe ist
/// schmerzhaft" that a participant list is not.
///
/// [isActive] rather than deleting: a route the group has stopped walking still
/// has rounds recorded under it, and the server only lets the coordination
/// delete one. Retiring keeps both the rounds and the route that produced them.
@freezed
abstract class Tour with _$Tour {
  const factory Tour({
    required String id,
    required String name,
    @Default(true) bool isActive,
    String? org,
    String? note,
    int? sortIndex,
    DateTime? created,
    DateTime? updated,
  }) = _Tour;

  factory Tour.fromRecord(RecordModel r) => Tour(
    id: r.id,
    name: pbString(r.data['name']) ?? '',
    isActive: pbBool(r.data['is_active']),
    org: pbString(r.data['org']),
    note: pbString(r.data['note']),
    sortIndex: pbInt(r.data['sort_index']),
    created: pbDate(r.data['created']),
    updated: pbDate(r.data['updated']),
  );
}

/// One stop on a route: which building, in which position.
///
/// [spotName] comes from `expand=spot` and is the reason the list is one
/// request. A stop that showed an id would be a row nobody can read — an id
/// without a label next to it is a bug in this app.
@freezed
abstract class TourStop with _$TourStop {
  const factory TourStop({
    required String id,
    required String tour,
    required String spot,
    int? sortIndex,
    String? org,

    /// The building's name, from `expand=spot`. Null when the expand was not
    /// asked for — never a fallback to the id.
    String? spotName,
    DateTime? created,
    DateTime? updated,
  }) = _TourStop;

  factory TourStop.fromRecord(RecordModel r) => TourStop(
    id: r.id,
    tour: pbString(r.data['tour']) ?? '',
    spot: pbString(r.data['spot']) ?? '',
    sortIndex: pbInt(r.data['sort_index']),
    org: pbString(r.data['org']),
    spotName: pbString(r.get<Object?>('expand.spot.name')),
    created: pbDate(r.data['created']),
    updated: pbDate(r.data['updated']),
  );
}

/// One **walking** of a route: on one day, by one person.
///
/// [tour] is null for the improvised round — three overdue buildings on the way
/// home. That is not a degenerate case of a template, it is the other half of
/// the feature: tour scale in this group varies from one building to a planned
/// full-day sweep, and a model that required a template first would push the
/// small case out of the app entirely. Somebody then walks it and writes
/// nothing, which is the WhatsApp history again.
///
/// [tourName] and [startedByName] are the server's snapshots, not
/// denormalisation for speed. Neither relation cascades — a retired template
/// and a closed account both leave their rounds standing — so the ids can go
/// empty, and an id whose target is gone describes the past wrongly. An empty
/// [tourName] means "improvised", which is a different statement from "the
/// template is gone".
///
/// [finishedAt] IS the open/closed state. There is no second flag to fall out
/// of step with it, and the server refuses to move it once set.
@freezed
abstract class TourRun with _$TourRun {
  const factory TourRun({
    required String id,
    String? tour,
    @Default('') String tourName,
    String? startedBy,
    String? startedByName,
    DateTime? startedAt,
    DateTime? finishedAt,
    String? note,
    String? org,
    DateTime? created,
    DateTime? updated,
  }) = _TourRun;

  factory TourRun.fromRecord(RecordModel r) => TourRun(
    id: r.id,
    tour: pbString(r.data['tour']),
    tourName: pbString(r.data['tour_name']) ?? '',
    startedBy: pbString(r.data['started_by']),
    startedByName: pbString(r.data['started_by_name']),
    startedAt: pbDate(r.data['started_at']),
    finishedAt: pbDate(r.data['finished_at']),
    note: pbString(r.data['note']),
    org: pbString(r.data['org']),
    created: pbDate(r.data['created']),
    updated: pbDate(r.data['updated']),
  );
}

/// What a screen needs to read off a round.
extension TourRunState on TourRun {
  /// Still going. The dashboard's "Tour 1 fortsetzen" is exactly this.
  bool get isOpen => finishedAt == null;

  /// Whether this round followed a template at all.
  ///
  /// Reads the NAME and not the relation: a template that was deleted leaves
  /// [tour] empty while the round it produced was still a walking of "Tour 1",
  /// and calling that improvised afterwards would rewrite what happened.
  bool get isAdHoc => tourName.isEmpty;
}
