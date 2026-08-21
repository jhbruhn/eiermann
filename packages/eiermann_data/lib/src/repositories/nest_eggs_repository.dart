import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_data/zugvogel_data.dart';

/// Reads `nest_eggs`: the Ist-Gelege of one nest, slot by slot.
///
/// **Read-only by type**, and not because of a convention: the collection has
/// no create, update or delete rule at all. The only writer is
/// `POST /api/eiermann/visit`, which rewrites the whole row set from the
/// outcome of a check. `PbReadOnlyRepository` makes an egg written from a
/// screen a compile error rather than the 400 it would otherwise be.
///
/// The dossier's nest LIST does not read this — it reads the counts off
/// `nest_state`, in one query for the whole building. What this is for is the
/// egg-slot row of one nest, where each slot needs its own `since`: "1 Kunstei
/// seit 12 Tagen" is a per-egg fact, and a count cannot carry it.
class NestEggsRepository extends PbReadOnlyRepository<NestEgg> {
  NestEggsRepository(PocketBase pb)
    : super(pb: pb, collection: 'nest_eggs', fromRecord: NestEgg.fromRecord);

  /// The eggs in one nest, in slot order.
  ///
  /// Unpaged: a nest holds two or three eggs. Sorted by the slot rather than by
  /// `since`, because the row on screen is the row in the nest — the endpoint
  /// writes real eggs first and then dummies, and re-sorting here would make
  /// the same clutch look different from one visit to the next.
  Future<List<NestEgg>> forNest(String nestId) => list(
    filter: filterExpr('nest = {:nest}', {'nest': nestId}),
    sort: 'slot_index',
  );
}
