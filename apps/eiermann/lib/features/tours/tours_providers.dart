import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/spots/spots_providers.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'tours_providers.g.dart';

/// Every route template, retired ones included — the Touren screen's read.
@riverpod
Future<List<Tour>> allTours(Ref ref) async {
  final repo = await ref.watch(toursRepositoryProvider.future);
  return repo.all();
}

/// The templates still in use — what the "Tour starten" picker offers.
@riverpod
Future<List<Tour>> activeTours(Ref ref) async {
  final repo = await ref.watch(toursRepositoryProvider.future);
  return repo.active();
}

/// One route, in order, with each stop's building name.
@riverpod
Future<List<TourStop>> tourStops(Ref ref, String tourId) async {
  final repo = await ref.watch(tourStopsRepositoryProvider.future);
  return repo.forTour(tourId);
}

/// One round.
@riverpod
Future<TourRun> tourRun(Ref ref, String runId) async {
  final repo = await ref.watch(tourRunsRepositoryProvider.future);
  return repo.getOne(runId);
}

/// The visits recorded on one round — which is what its progress IS.
@riverpod
Future<List<Visit>> tourRunVisits(Ref ref, String runId) async {
  final repo = await ref.watch(visitLogRepositoryProvider.future);
  return repo.forRun(runId);
}

/// My own round that is still going, or null.
///
/// This is what makes a round survive the app being killed: the open row on the
/// server IS the resume point, so nothing is kept on the device and the
/// dashboard can offer "Tour 1 fortsetzen" on a phone that has been rebooted
/// since. The alternative — a local draft — would come back on one device only,
/// and would disagree with the visits already written from the other.
///
/// Watches the user's ID and not the user, so a token refresh — every resume,
/// and on web every time the tab regains focus — does not re-run this query.
@riverpod
Future<TourRun?> myOpenRun(Ref ref) async {
  final me = await ref.watch(currentUserProvider.selectAsync((u) => u?.id));
  if (me == null) return null;
  final repo = await ref.watch(tourRunsRepositoryProvider.future);
  return repo.openFor(me);
}

/// One round's progress: the route, plus what was actually visited on it.
///
/// Three reads, and every one of them is shared with another screen: the stops
/// (only this screen), the round's visits (only this screen), and
/// [allSpotsProvider] — the unpaged `spot_overview` set the map and the
/// dashboard already hold. That last one is why a stop can show its urgency and
/// its due date without a request per row.
///
/// A round with no template has no stops at all, and that is the whole ad-hoc
/// mode: every entry is an addition.
@riverpod
Future<TourProgress> tourRunProgress(Ref ref, String runId) async {
  final run = await ref.watch(tourRunProvider(runId).future);
  final visits = await ref.watch(tourRunVisitsProvider(runId).future);
  final stops = run.tour == null
      ? const <TourStop>[]
      : await ref.watch(tourStopsProvider(run.tour!).future);
  final spots = await ref.watch(allSpotsProvider.future);
  return tourProgress(
    stops: stops,
    visits: visits,
    spotNames: {for (final spot in spots) spot.id: spot.name},
  );
}

/// Invalidates every read that draws a route or a round.
///
/// Enumerated rather than a global refresh, and the enumeration is the
/// documentation: a reader that goes missing here shows the route from before
/// the edit and looks like a caching bug somewhere else entirely.
void invalidateTourViews(WidgetRef ref) {
  ref
    ..invalidate(allToursProvider)
    ..invalidate(activeToursProvider)
    ..invalidate(tourStopsProvider);
}

/// Invalidates every read that draws a round.
///
/// Separate from [invalidateTourViews] because the two writes are different
/// events: editing a template does not change a round, and walking a round does
/// not change a template. Calling both from one place would make every visit
/// re-read the whole Touren screen.
void invalidateRunViews(WidgetRef ref) {
  ref
    ..invalidate(myOpenRunProvider)
    ..invalidate(tourRunProvider)
    ..invalidate(tourRunVisitsProvider)
    ..invalidate(tourRunProgressProvider);
}
