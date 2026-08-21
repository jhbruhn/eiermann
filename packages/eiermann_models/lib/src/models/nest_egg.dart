import 'package:eiermann_models/src/enums.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

part 'nest_egg.freezed.dart';

/// One egg currently in a nest — one row of `nest_eggs`, the **Ist-Gelege**.
///
/// Read-only for every client: only the visit endpoint writes here, and it
/// rewrites the whole row set from the outcome of a check. So this is a
/// *projection* of the check history, not a thing anybody edits.
///
/// [since] is the date THIS egg has been in the nest, and it survives a
/// rewrite: a dummy that has sat for three months is a nest the birds have
/// given up on, and that signal is the reason the field is per egg rather than
/// per nest. Read the age through [ageInDays], never by subtracting raw
/// timestamps.
@freezed
abstract class NestEgg with _$NestEgg {
  const factory NestEgg({
    required String id,
    required String nest,

    /// What is in the slot, or null for a `kind` this build has no name for.
    ///
    /// Nullable rather than defaulted: an egg of an unknown kind counted as a
    /// dummy would tell the volunteer to pack one fewer Attrappe, and counted
    /// as real would send somebody out for a swap that is not due. The slot is
    /// still DRAWN — as an unreadable one — because a row that exists and
    /// cannot be shown is worse than one that says so.
    EggKind? kind,
    String? org,

    /// Position in the egg row. Zero is a real slot — the first one — so this
    /// is read with `pbInt`, never `pbCount`.
    @Default(0) int slotIndex,
    DateTime? since,
    String? sourceCheck,
    DateTime? created,
    DateTime? updated,
  }) = _NestEgg;

  factory NestEgg.fromRecord(RecordModel r) => NestEgg(
    id: r.id,
    nest: pbString(r.data['nest']) ?? '',
    kind: EggKind.fromWire(r.data['kind']),
    org: pbString(r.data['org']),
    slotIndex: pbInt(r.data['slot_index']) ?? 0,
    since: pbDate(r.data['since']),
    sourceCheck: pbString(r.data['source_check']),
    created: pbDate(r.data['created']),
    updated: pbDate(r.data['updated']),
  );
}

/// How long this egg has been where it is.
extension NestEggAge on NestEgg {
  /// Whole days between [since] and [now], on LOCAL calendar days.
  ///
  /// Local and truncated to dates, for the reason the whole app converts dates
  /// in one place: PocketBase stores UTC, so an egg recorded at 23:30 CET sits
  /// on the previous UTC day and a raw subtraction reports a day too many for
  /// half of every evening. Null when the row carries no date at all.
  int? ageInDays(DateTime now) {
    final from = since?.toLocal();
    if (from == null) return null;
    final to = now.toLocal();
    return DateTime(
      to.year,
      to.month,
      to.day,
    ).difference(DateTime(from.year, from.month, from.day)).inDays;
  }
}
