import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann_models/eiermann_models.dart';
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

/// The label to suggest for the next nest in [existing].
///
/// "N" plus the first free number, so a Bereich fills up as N1, N2, N3 — the
/// captions volunteers say out loud. It skips numbers already taken rather than
/// counting the rows: a Bereich that had N1..N3 and lost N2 must not propose a
/// second N3, because the label is UNIQUE per Bereich and the write would be
/// refused after the sheet was already filled in.
String suggestNestLabel(List<Nest> existing) {
  final taken = existing.map((nest) => nest.label).toSet();
  for (var n = 1; n <= taken.length + 1; n++) {
    final candidate = 'N$n';
    if (!taken.contains(candidate)) return candidate;
  }
  // Unreachable: the loop tries one more number than there are labels.
  return 'N${taken.length + 1}';
}
