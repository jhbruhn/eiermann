import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'nests_providers.g.dart';

/// Every nest of one Bereich — the pins for one photo.
///
/// Unpaged and by label: a Bereich holds a handful, and a pin editor that
/// showed only the first page would leave nests invisible on the one screen
/// that can place them.
@riverpod
Future<List<Nest>> nestsForArea(Ref ref, String areaId) async {
  final repo = await ref.watch(nestsRepositoryProvider.future);
  return repo.forArea(areaId);
}

/// Every nest of one building, urgent first — with what is in it.
///
/// Reads `nest_state` and ONLY that: one query for the whole dossier, however
/// many Bereiche it has. The alternative is a request per Bereich and then one
/// per nest for its eggs, which is the shape that makes this app feel broken on
/// a phone in a stairwell.
@riverpod
Future<List<NestState>> nestStatesForSpot(Ref ref, String spotId) async {
  final repo = await ref.watch(nestStateRepositoryProvider.future);
  return repo.forSpot(spotId);
}

/// Invalidates every read that draws a nest.
///
/// Two of them now — the editor's pins read `nests`, the dossier's list reads
/// the view over it — and a writer that refreshed only one would leave the
/// other showing what was true a moment ago. The same lesson
/// `invalidateSpotViews` exists for.
void invalidateNestViews(WidgetRef ref) {
  ref
    ..invalidate(nestsForAreaProvider)
    ..invalidate(nestStatesForSpotProvider);
}

/// The label to suggest for the next nest, given the [labels] already taken.
///
/// "N" plus the first free number, so a Bereich fills up as N1, N2, N3 — the
/// captions volunteers say out loud. It skips numbers already taken rather than
/// counting the rows: a Bereich that had N1..N3 and lost N2 must not propose a
/// second N3, because the label is UNIQUE per Bereich and the write would be
/// refused after the sheet was already filled in.
///
/// Labels rather than rows, because both callers hold a different shape of the
/// same nests — the editor has `nests` rows, the dossier's list has rows of the
/// view over them.
String suggestNestLabel(Iterable<String> labels) {
  final taken = labels.toSet();
  for (var n = 1; n <= taken.length + 1; n++) {
    final candidate = 'N$n';
    if (!taken.contains(candidate)) return candidate;
  }
  // Unreachable: the loop tries one more number than there are labels.
  return 'N${taken.length + 1}';
}
