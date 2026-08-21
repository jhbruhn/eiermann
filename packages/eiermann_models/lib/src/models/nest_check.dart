import 'package:eiermann_models/src/enums.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

part 'nest_check.freezed.dart';

/// A recorded check on one nest — the read side of `NestCheckDraft`.
///
/// **Immutable, and the collection says so**: `nest_checks` has no create,
/// update or delete rule at all. The only writer is the transactional visit
/// endpoint, and nothing may edit a check afterwards, because `nest_eggs` and
/// the nests' rhythm state are derived from these rows. A check corrected by
/// hand would leave the derived state describing a visit that did not happen.
///
/// [state] is the state the SERVER decided, which is not always the one the
/// form requested: [CheckState.partial] is derived from the arithmetic, as the
/// Nachkontrolle that keeps a half clutch from hatching unnoticed hangs off
/// exactly that flag.
@freezed
abstract class NestCheck with _$NestCheck {
  const factory NestCheck({
    required String id,
    String? visit,
    String? nest,
    CheckState? state,
    @Default(0) int realBefore,
    @Default(0) int dummyBefore,
    @Default(0) int realAfter,
    @Default(0) int dummyAfter,
    @Default(0) int removedReal,
    @Default(0) int addedDummy,
    String? note,

    /// Who checked it, as a NAME — a snapshot, so a closed account does not
    /// take the checks it made with it.
    String? authorName,
    DateTime? checkedAt,

    /// The nest's label, from `expand=nest`. An id with no label next to it is
    /// a bug in this app, and "N3" is what somebody says out loud.
    String? nestLabel,
    String? org,
  }) = _NestCheck;

  factory NestCheck.fromRecord(RecordModel r) => NestCheck(
    id: r.id,
    visit: pbString(r.data['visit']),
    nest: pbString(r.data['nest']),
    state: CheckState.fromWire(r.data['state']),
    // Zero is a real reading — an empty nest — so `pbInt` throughout and never
    // `pbCount`: "no eggs" and "nothing recorded" are the same fact about a
    // count of eggs.
    realBefore: pbInt(r.data['real_before']) ?? 0,
    dummyBefore: pbInt(r.data['dummy_before']) ?? 0,
    realAfter: pbInt(r.data['real_after']) ?? 0,
    dummyAfter: pbInt(r.data['dummy_after']) ?? 0,
    removedReal: pbInt(r.data['removed_real']) ?? 0,
    addedDummy: pbInt(r.data['added_dummy']) ?? 0,
    note: pbString(r.data['note']),
    authorName: pbString(r.data['author_name']),
    checkedAt: pbDate(r.data['checked_at']),
    nestLabel: pbString(r.get<Object?>('expand.nest.label')),
    org: pbString(r.data['org']),
  );
}
