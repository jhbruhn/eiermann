import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_data/zugvogel_data.dart';

/// Reads and writes `nests` — the pins on a Bereich's photo, and the rows the
/// whole rhythm hangs off.
///
/// Four things this repository will not let a caller do, each because the
/// server refuses it anyway and a silent 400 is a worse answer than a compile
/// error or a loud exception:
///
/// * **No delete.** A nest is never deleted; `status = gone` records that it is
///   no longer there, which is a FINDING — a nest that disappeared is
///   information about the building. The collection has `deleteRule: null`, so
///   not even the coordination has this route. See [delete].
/// * **No `spot`.** It is denormalised for the sake of one-table reads, and a
///   hook derives it from the area on every write. A client that sent it could
///   make a nest claim a building its Bereich does not belong to.
/// * **No rhythm fields.** `interval_days`, `empty_streak` and `next_due_at`
///   are the ladder's state, written only by the rhythm library. A client that
///   can set them can make a nest look checked without anybody going there.
/// * **No re-parenting.** `area` goes on create only; the update rule pins it,
///   because moving a nest would carry its whole check history to another
///   building.
class NestsRepository extends PbRepository<Nest> {
  NestsRepository(PocketBase pb)
    : super(pb: pb, collection: 'nests', fromRecord: Nest.fromRecord);

  /// Every nest of one Bereich — the pins for one photo.
  ///
  /// By label, because that is what the photo's pins are captioned with and
  /// what the volunteer says out loud ("N3 ist leer"). Unpaged: a Bereich holds
  /// a handful, and a pin editor that showed the first page would leave nests
  /// invisible on the only screen that can place them.
  Future<List<Nest>> forArea(String areaId) => list(
    filter: filterExpr('area = {:area}', {'area': areaId}),
    sort: 'label',
  );

  /// Writes just the pin, normalised.
  ///
  /// Its own method rather than a `body()` call: a drag changes two numbers and
  /// nothing else, and sending the whole record back would let a stale label or
  /// species — read before somebody else edited it — overwrite the current one.
  Future<Nest> movePin(String id, {required double x, required double y}) =>
      update(id, {'pin_x': normalisePin(x), 'pin_y': normalisePin(y)});

  /// The body a create or an update sends.
  ///
  /// [area] and [org] belong to the create path only. [species] and [status]
  /// are required by the collection: an undetermined nest is
  /// [NestSpecies.unknown], a real state and not a silent "city pigeon".
  static Map<String, dynamic> body({
    required String label,
    required NestSpecies species,
    required NestStatus status,
    String? positionHint,
    String? speciesLabel,
    String? note,
    double? pinX,
    double? pinY,
    String? area,
    String? org,
  }) => {
    'label': label,
    'species': species.wire,
    'status': status.wire,
    'position_hint': positionHint ?? '',
    'species_label': speciesLabel ?? '',
    'note': note ?? '',
    // Both or neither: half a pin is not a position, and an x with no y would
    // draw the nest along the top edge of the photo.
    if (pinX != null && pinY != null) ...{
      'pin_x': normalisePin(pinX),
      'pin_y': normalisePin(pinY),
    },
    'area': ?area,
    'org': ?org,
  };

  /// Always throws. A nest is never deleted — see the class doc.
  ///
  /// Overridden rather than left inherited: the base class offers `delete`
  /// because most collections have it, and a call here would otherwise compile,
  /// reach the server and come back 403 at the worst possible moment. Failing
  /// in the client names the reason instead.
  @override
  Future<void> delete(String id) => throw UnsupportedError(
    'nests are never deleted — set status = gone, which records that the nest '
    'is no longer there instead of erasing every check made on it',
  );
}
