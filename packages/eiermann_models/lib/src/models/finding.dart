import 'package:eiermann_models/src/enums.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

part 'finding.freezed.dart';

/// A recorded **Fund** — what was found at a building that was not an egg.
///
/// The read side of what `FindingDraft` writes, and a separate type for the
/// same reason `Visit` is: a draft is something somebody is still filling in,
/// this is a fact with an id nothing but the visit endpoint could have made.
///
/// [nest] is optional because a dead bird on the floor of a stairwell belongs
/// to no nest. [nestLabel] comes from `expand=nest`, and it is not decoration:
/// an id with no label next to it is a bug in this app, and a chronology saying
/// "Fund an gu3k1..." would be unreadable exactly where it matters.
///
/// [authorName] is a SNAPSHOT and not a lookup. A closed account must not take
/// the Funde it recorded with it, and a chronology whose author column empties
/// when somebody leaves the group describes the past wrongly.
@freezed
abstract class Finding with _$Finding {
  const factory Finding({
    required String id,
    required String spot,
    String? visit,
    String? nest,
    FindingKind? kind,
    @Default(0) int count,
    String? speciesLabel,
    String? note,

    /// The file name, or null. Findings written by the visit endpoint carry
    /// none — a file cannot travel in the JSON body of a transaction — so this
    /// is filled in by the upload that follows (`eiermann-9oa`).
    String? photo,
    String? authorName,
    DateTime? foundAt,

    /// The nest's label, from `expand=nest`.
    String? nestLabel,

    /// The building's name, from `expand=spot` — for a list that spans
    /// buildings.
    String? spotName,
    String? org,
    DateTime? created,
  }) = _Finding;

  factory Finding.fromRecord(RecordModel r) => Finding(
    id: r.id,
    spot: pbString(r.data['spot']) ?? '',
    visit: pbString(r.data['visit']),
    nest: pbString(r.data['nest']),
    // Null for a kind this build has no name for, which reads as "the server
    // is newer than this app" rather than as one of the four it does know.
    kind: FindingKind.fromWire(r.data['kind']),
    // `pbInt`: the endpoint always writes at least 1, so a zero here is a row
    // written by something else and worth showing as it is rather than as 1.
    count: pbInt(r.data['count']) ?? 0,
    speciesLabel: pbString(r.data['species_label']),
    note: pbString(r.data['note']),
    photo: pbString(r.data['photo']),
    authorName: pbString(r.data['author_name']),
    foundAt: pbDate(r.data['found_at']),
    nestLabel: pbString(r.get<Object?>('expand.nest.label')),
    spotName: pbString(r.get<Object?>('expand.spot.name')),
    org: pbString(r.data['org']),
    created: pbDate(r.data['created']),
  );
}
