import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

part 'area.freezed.dart';

/// A **Bereich** — a named part of a building that carries the overview photo,
/// and with it the nest pins.
///
/// The photo is not decoration on a Bereich, it is what a Bereich is for: you
/// look at a picture of the attic and see where the nests are. Everything else
/// here supports that.
///
/// [photo] and [previousPhoto] are single-file fields, so the raw value is one
/// filename or the empty string — read as null when empty. Both are
/// **protected** on the server: it is the inside of somebody's building, and a
/// URL for it is only served against a short-lived file token.
///
/// [previousPhoto] and [pinsNeedReview] belong to the photo-replacement review
/// pass (eiermann-bmg.5): the outgoing photo is kept for exactly one generation
/// so old and new can be compared while every pin is confirmed or moved, and it
/// is deleted when the pass finishes. A history of photos of somebody's private
/// property is not harmless — it needs a purpose, continuously, and once the
/// pass is over there is none.
@freezed
abstract class Area with _$Area {
  const factory Area({
    required String id,
    required String name,
    required String spot,
    String? org,
    String? photo,
    String? previousPhoto,
    DateTime? photoTakenAt,
    @Default(false) bool pinsNeedReview,
    int? sortIndex,
    String? note,
    DateTime? created,
    DateTime? updated,
  }) = _Area;

  factory Area.fromRecord(RecordModel r) => Area(
    id: r.id,
    name: pbString(r.data['name']) ?? '',
    spot: pbString(r.data['spot']) ?? '',
    org: pbString(r.data['org']),
    photo: pbString(r.data['photo']),
    previousPhoto: pbString(r.data['previous_photo']),
    photoTakenAt: pbDate(r.data['photo_taken_at']),
    pinsNeedReview: pbBool(r.data['pins_need_review']),
    sortIndex: pbInt(r.data['sort_index']),
    note: pbString(r.data['note']),
    created: pbDate(r.data['created']),
    updated: pbDate(r.data['updated']),
  );
}

/// Whether this Bereich can carry pins at all.
///
/// A pin is a coordinate on a photo, so a Bereich without one has nowhere to
/// put a nest — the server refuses such a write (`nests.pb.js`) and the UI has
/// to say so before offering the gesture, not after.
extension AreaPins on Area {
  bool get hasPhoto => photo != null;
}
