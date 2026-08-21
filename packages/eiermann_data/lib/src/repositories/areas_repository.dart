import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_data/zugvogel_data.dart';

/// Reads and writes `areas` — the Bereiche of one building, each carrying the
/// overview photo the nest pins sit on.
///
/// The photo itself moves through `updateWithFiles` on the base class: a
/// multipart part named `photo`. Two things about that are not obvious and are
/// both deliberate:
///
/// * **The parent is frozen on update.** `spot` is only ever sent on create.
///   The collection's update rule refuses it, because an update rule resolves a
///   plain field reference against the STORED record — a re-parenting write
///   would be authorised against the old Spot while landing on the new one, and
///   it would take the Bereich's nests and their whole check history with it.
/// * **`previous_photo` and `pins_need_review` are the server's.** Replacing a
///   photo is a review pass, not a field update (eiermann-bmg.5): the hook
///   moves the outgoing file and raises the flag. A client that set them
///   itself could raise the flag without keeping the old photo, which leaves a
///   reviewer guessing at what moved.
class AreasRepository extends PbRepository<Area> {
  AreasRepository(PocketBase pb)
    : super(pb: pb, collection: 'areas', fromRecord: Area.fromRecord);

  /// Every Bereich of one Spot, in walking order.
  ///
  /// Unpaged: a building has a handful of Bereiche and the dossier shows all of
  /// them. The sort is the server's and `sort_index` comes first, because the
  /// order is physical — ground floor, then the attic — and alphabetical would
  /// scatter the route somebody actually walks. `name` breaks the tie so two
  /// Bereiche with no index yet still land in a stable order rather than record
  /// order.
  Future<List<Area>> forSpot(String spotId) => list(
    filter: filterExpr('spot = {:spot}', {'spot': spotId}),
    sort: 'sort_index,name',
  );

  /// The body a create or an update sends.
  ///
  /// [spot] belongs to the create path only — see the class doc. Nothing here
  /// can touch `photo`, `previous_photo` or `pins_need_review`: the file goes
  /// as a multipart part, and the other two are the hook's.
  static Map<String, dynamic> body({
    required String name,
    String? note,
    int? sortIndex,
    String? spot,
    String? org,
  }) => {
    'name': name,
    'note': note ?? '',
    'sort_index': ?sortIndex,
    'spot': ?spot,
    'org': ?org,
  };
}
