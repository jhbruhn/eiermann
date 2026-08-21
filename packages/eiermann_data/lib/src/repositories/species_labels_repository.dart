import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_data/zugvogel_data.dart';

/// Reads the `species_labels` view: what this organisation has actually called
/// the birds it has seen.
///
/// **Read-only by type.** `PbReadOnlyRepository` has no create/update/delete, so
/// "add a species to the list" is a compile error rather than the runtime 400 a
/// write against a PocketBase view would be. That is the design and not a
/// limitation: the vocabulary grows by being USED, and a writable list is a
/// curated list — the thing this view exists instead of.
class SpeciesLabelsRepository extends PbReadOnlyRepository<SpeciesLabel> {
  SpeciesLabelsRepository(PocketBase pb)
    : super(
        pb: pb,
        collection: 'species_labels',
        fromRecord: SpeciesLabel.fromRecord,
      );

  /// The whole vocabulary, most-used first.
  ///
  /// Unpaged, and that is a bet worth stating: this is one org's species names,
  /// which is tens of rows in a city and not thousands. The alternative — a
  /// server-side search per keystroke — would put a request behind every letter
  /// typed in a stairwell, for a list that fits in memory. So it is fetched
  /// once and filtered locally.
  ///
  /// `-used_count` first because frequency is the better ordering for a picker:
  /// the bird somebody is about to type is much more often the one they typed
  /// last week than the one that sorts first. `label` breaks the ties, so the
  /// long tail is alphabetical and stable rather than in whatever order SQLite
  /// grouped it.
  Future<List<SpeciesLabel>> all() => list(sort: '-used_count,label');
}
