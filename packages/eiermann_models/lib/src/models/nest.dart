import 'package:eiermann_models/src/enums.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

part 'nest.freezed.dart';

/// Smallest coordinate a pin may be WRITTEN at.
///
/// The wire cannot tell an unset number field from a deliberate zero — an
/// unpinned nest comes back as `pin_x: 0, pin_y: 0`, measured against the
/// running server — and `pin_x: 0, pin_y: 0` is also a legal pin, the top-left
/// corner of the photo. Worse, the server clamps into 0…1, so a drag INTO that
/// corner lands on exactly the ambiguous value.
///
/// So the reader treats (0, 0) as "no pin" (see [NestPin.pin]) and the writer
/// never produces it: a coordinate is nudged to this minimum instead. At the
/// pin editor's 1200px working width that is a shift of about one pixel — less
/// than the pin's own outline — while it makes the one ambiguous point on the
/// photo unreachable.
const double kPinMin = 0.001;

/// One nest — the centre of the machinery.
///
/// The Rhythmus ladder runs per nest, the checks hang off it, and the
/// protected-species guard keys on it.
///
/// [pinX] and [pinY] are **normalised 0…1, never pixels**: a pin in pixels is a
/// pin measured against one image at one size, and a new photo or a wider
/// screen would silently move every nest on the map. Read them through [pin],
/// which is the only reader that knows about the (0, 0) collision.
///
/// [intervalDays], [emptyStreak] and [nextDueAt] are the ladder's state and are
/// refused from a client by the collection's update rule. Read them, never send
/// them: a client that can set them can make a nest look checked without
/// anybody going there.
///
/// [species] is a **safety field, not a label**. [NestSpecies.unknown] is a
/// real state and never a silent assumption of "city pigeon" — the app does
/// not identify species, and an undetermined nest stays an open question until
/// a person decides.
@freezed
abstract class Nest with _$Nest {
  const factory Nest({
    required String id,
    required String label,
    required String area,
    String? spot,
    String? org,
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
    DateTime? created,
    DateTime? updated,
  }) = _Nest;

  factory Nest.fromRecord(RecordModel r) => Nest(
    id: r.id,
    label: pbString(r.data['label']) ?? '',
    area: pbString(r.data['area']) ?? '',
    // Denormalised on purpose, and derived by a hook from the area on every
    // write — the client never sends it.
    spot: pbString(r.data['spot']),
    org: pbString(r.data['org']),
    positionHint: pbString(r.data['position_hint']),
    // `pbDouble`, not `pbQuantity`: zero is a real coordinate on one axis. The
    // pair being zero is what means "unset", and only [pin] may decide that.
    pinX: pbDouble(r.data['pin_x']),
    pinY: pbDouble(r.data['pin_y']),
    photo: pbString(r.data['photo']),
    species: NestSpecies.fromWire(r.data['species']),
    speciesLabel: pbString(r.data['species_label']),
    status: NestStatus.fromWire(r.data['status']),
    // A rung of the ladder is at least one day, so a zero here is an unset
    // field rather than a rhythm — a nest that has never been checked.
    intervalDays: pbCount(r.data['interval_days']),
    // Zero IS a real reading: this nest's last check found eggs.
    emptyStreak: pbInt(r.data['empty_streak']),
    nextDueAt: pbDate(r.data['next_due_at']),
    note: pbString(r.data['note']),
    created: pbDate(r.data['created']),
    updated: pbDate(r.data['updated']),
  );
}

/// Where the nest sits on its Bereich's photo, as normalised coordinates.
extension NestPin on Nest {
  /// The pin, or null when this nest has none.
  ///
  /// A pin needs BOTH coordinates, and (0, 0) reads as none — see [kPinMin]
  /// for the measurement behind that. The record is returned as one value
  /// because half a pin is not a position: an x with no y would be drawn at the
  /// top edge of the photo, which is a claim about the building nobody made.
  ({double x, double y})? get pin {
    final x = pinX;
    final y = pinY;
    if (x == null || y == null) return null;
    if (x == 0 && y == 0) return null;
    return (x: x, y: y);
  }

  bool get hasPin => pin != null;

  /// Whether this nest may not be touched: a protected species is refused
  /// every egg mutation on every path, server-side.
  bool get isProtected => species == NestSpecies.protected;
}

/// Moves a coordinate into the range a pin may be written at.
///
/// Clamped rather than refused, because these arrive from a drag: a pin dropped
/// on the edge routinely computes to 1.0000000002, and failing there would mean
/// a volunteer cannot place a nest at the edge of a photo — which is where roof
/// nests actually are. The server clamps too (`app_nest_rules.js`); this is the
/// half that also keeps (0, 0) unreachable. See [kPinMin].
double normalisePin(double raw) {
  if (raw.isNaN) return kPinMin;
  return raw.clamp(kPinMin, 1);
}
