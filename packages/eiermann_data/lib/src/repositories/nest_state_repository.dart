import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_data/zugvogel_data.dart';

/// Reads the `nest_state` view: the dossier's nest list in one query.
///
/// **Read-only by type.** `PbReadOnlyRepository` has no create/update/delete, so
/// a write against a PocketBase view is a compile error here rather than the
/// runtime 400 it would otherwise be. Writes go to `NestsRepository`.
class NestStateRepository extends PbReadOnlyRepository<NestState> {
  NestStateRepository(PocketBase pb)
    : super(
        pb: pb,
        collection: 'nest_state',
        fromRecord: NestState.fromRecord,
      );

  /// The order the nest list uses: loudest first, then by label.
  ///
  /// `label` second so a building with four nests in rhythm lists them N1..N4
  /// rather than in record order — the labels are what somebody reads out loud
  /// while standing in the attic.
  static const _urgentFirst = 'urgency,label';

  /// Every nest of one building, urgent first.
  ///
  /// Unpaged: this is the block that has to stand on the dossier without
  /// scrolling, and a building has a handful of nests. `spot` is denormalised
  /// onto the nest for exactly this read — one table, no join.
  Future<List<NestState>> forSpot(String spotId) => list(
    filter: filterExpr('spot = {:spot}', {'spot': spotId}),
    sort: _urgentFirst,
  );

  /// Every nest of one Bereich, urgent first — the pins for one photo.
  Future<List<NestState>> forArea(String areaId) => list(
    filter: filterExpr('area = {:area}', {'area': areaId}),
    sort: _urgentFirst,
  );
}
