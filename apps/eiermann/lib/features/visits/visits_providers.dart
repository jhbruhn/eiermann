import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/nests/nests_providers.dart';
import 'package:eiermann/features/spots/spots_providers.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'visits_providers.g.dart';

/// The Ist-Gelege of one nest, slot by slot.
///
/// Read for the CHECK SHEET only. The dossier's nest list gets its counts off
/// `nest_state` in one query for the whole building; this is the read that also
/// needs each egg's own `since`, because "1 Kunstei seit 12 Tagen" is a per-egg
/// fact and a count cannot carry it.
@riverpod
Future<List<NestEgg>> nestEggs(Ref ref, String nestId) async {
  final repo = await ref.watch(nestEggsRepositoryProvider.future);
  return repo.forNest(nestId);
}

/// Every open Nachkontrolle in the org, earliest first — the dashboard's top
/// block.
@riverpod
Future<List<FollowUp>> openFollowUps(Ref ref) async {
  final repo = await ref.watch(followUpsRepositoryProvider.future);
  return repo.open();
}

/// The open Nachkontrollen of one building — the dossier's second date, and the
/// reason its due date is earlier than the rhythm would have made it.
@riverpod
Future<List<FollowUp>> openFollowUpsForSpot(Ref ref, String spotId) async {
  final repo = await ref.watch(followUpsRepositoryProvider.future);
  return repo.openForSpot(spotId);
}

/// Invalidates everything a written visit changes.
///
/// A visit is the widest write in this app: it moves the eggs, the nests'
/// rhythm state, the Spot's due date and the follow-ups, so every list that
/// reads any of those is stale at once. Enumerated rather than a global
/// refresh, and the enumeration is the documentation — a reader that goes
/// missing here shows the state from before the visit and looks like a caching
/// bug somewhere else entirely.
void invalidateAfterVisit(WidgetRef ref) {
  invalidateNestViews(ref);
  invalidateSpotViews(ref);
  ref
    ..invalidate(spotProvider)
    ..invalidate(nestEggsProvider)
    ..invalidate(openFollowUpsProvider)
    ..invalidate(openFollowUpsForSpotProvider);
  // `species_labels` is covered by invalidateNestViews above, and it has to be:
  // a species typed on a FUND is in the same vocabulary as one typed on a nest.
}
