import 'package:eiermann_models/src/enums.dart';
import 'package:eiermann_models/src/models/nest.dart' show pinOf;
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

part 'nest_state.freezed.dart';

/// One row of the `nest_state` view: a nest plus what is in it and how old that
/// is — everything the dossier's nest list draws, in one query.
///
/// The counts are the **Ist-Gelege**: how many real eggs and how many dummies
/// are in that nest right now. [oldestSince] is the date the longest-standing
/// egg has been there, and [lastCheckedAt] the last time anybody looked. Both
/// arrive RAW rather than as a day count, because a difference computed on
/// the server is right in Greenwich and a day out in CET for anything
/// recorded after 22:00 local — see [ageInDays], which subtracts on LOCAL
/// dates.
@freezed
abstract class NestState with _$NestState {
  const factory NestState({
    required String id,
    required String label,
    required String area,
    required int urgency,
    String? org,
    String? spot,
    String? positionHint,
    double? pinX,
    double? pinY,
    String? photo,
    NestSpecies? species,
    String? speciesLabel,
    NestStatus? status,
    int? intervalDays,
    int? emptyStreak,
    DateTime? nextDueAt,
    String? note,
    @Default(0) int realCount,
    @Default(0) int dummyCount,
    DateTime? oldestSince,
    DateTime? lastCheckedAt,
    DateTime? created,
    DateTime? updated,
  }) = _NestState;

  factory NestState.fromRecord(RecordModel r) => NestState(
    id: r.id,
    label: pbString(r.data['label']) ?? '',
    area: pbString(r.data['area']) ?? '',
    urgency: pbInt(r.data['urgency']) ?? NestUrgency.inRhythm.rank,
    org: pbString(r.data['org']),
    spot: pbString(r.data['spot']),
    positionHint: pbString(r.data['position_hint']),
    pinX: pbDouble(r.data['pin_x']),
    pinY: pbDouble(r.data['pin_y']),
    photo: pbString(r.data['photo']),
    species: NestSpecies.fromWire(r.data['species']),
    speciesLabel: pbString(r.data['species_label']),
    status: NestStatus.fromWire(r.data['status']),
    intervalDays: pbCount(r.data['interval_days']),
    emptyStreak: pbInt(r.data['empty_streak']),
    nextDueAt: pbDate(r.data['next_due_at']),
    note: pbString(r.data['note']),
    // Zero is a real reading here — an empty nest — so `pbInt`, never
    // `pbCount`: "no eggs" and "nothing recorded" are the same thing for a
    // count of the rows that exist.
    realCount: pbInt(r.data['real_count']) ?? 0,
    dummyCount: pbInt(r.data['dummy_count']) ?? 0,
    oldestSince: pbDate(r.data['oldest_since']),
    lastCheckedAt: pbDate(r.data['last_checked_at']),
    created: pbDate(r.data['created']),
    updated: pbDate(r.data['updated']),
  );
}

/// What the nest list reads off a row.
extension NestStateReading on NestState {
  /// How many eggs are in the nest, of either kind.
  int get eggCount => realCount + dummyCount;

  bool get isEmpty => eggCount == 0;

  bool get isProtected => species == NestSpecies.protected;

  /// Where this nest sits on its Bereich's photo, through the same derivation
  /// the `nests` rows use — see [pinOf].
  ({double x, double y})? get pin => pinOf(pinX, pinY);

  bool get hasPin => pin != null;

  bool get isGone => status == NestStatus.gone;

  /// The named rank, or null for one this build has no name for.
  NestUrgency? get level => NestUrgency.fromRank(urgency);

  /// The date the age on the list line is measured from: when the oldest egg
  /// arrived, or — for an empty nest — when anybody last looked.
  ///
  /// The clutch wins where there is one, because that is the number the work
  /// turns on: a dummy that has sat for months is a nest the birds have given
  /// up on, and that is worth seeing over "checked last week".
  DateTime? get ageSince => oldestSince ?? lastCheckedAt;

  /// Whole days between [ageSince] and [now], on LOCAL calendar days.
  ///
  /// Local, and truncated to dates: PocketBase stores UTC, so an egg recorded
  /// at 23:30 CET is stored on the previous UTC day, and subtracting the raw
  /// timestamps would report a day too many for half of every evening. Null
  /// when nothing has happened to this nest at all — which is a state to say
  /// out loud, not a zero.
  int? ageInDays(DateTime now) {
    final since = ageSince;
    if (since == null) return null;
    final from = since.toLocal();
    final to = now.toLocal();
    return DateTime(
      to.year,
      to.month,
      to.day,
    ).difference(DateTime(from.year, from.month, from.day)).inDays;
  }
}
