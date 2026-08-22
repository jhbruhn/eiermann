import 'package:eiermann_models/src/enums.dart';
import 'package:eiermann_models/src/models/tour.dart';
import 'package:eiermann_models/src/models/visit.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

/// What has happened to one building on a round.
///
/// Not a `WireEnum`: nothing stores this. It is derived on the client from
/// whether the stop has a visit and what that visit's outcome was — the row
/// the server holds is the Besuch, and this is how the progress list reads it.
enum TourStopState {
  /// Planned, not reached yet. The only state a stop can be in without a visit.
  pending,

  /// Visited and checked.
  checked,

  /// Visited and deliberately not checked — no key, nobody there, a building
  /// site. An outcome, not a failure: it is the same row shape as [checked] and
  /// carries a reason.
  skipped,
}

/// One line of a round's progress list.
///
/// [planned] is false for a building somebody added while walking. Those sit
/// after the route rather than inside it: inserting them would claim the
/// template says something it does not, and the reader is standing in front of
/// the template.
@immutable
class TourStopProgress {
  const TourStopProgress({
    required this.spot,
    required this.state,
    required this.planned,
    this.stopId,
    this.spotName,
    this.visitId,
    this.visitedAt,
    this.skipReason,
  });

  final String spot;
  final TourStopState state;

  /// Whether the template listed this building.
  final bool planned;

  /// The `tour_spots` row, for the planned ones. Null for an addition — there
  /// is nothing to reorder or remove.
  final String? stopId;

  final String? spotName;

  /// The visit that settled this stop, or null while it is still
  /// [TourStopState.pending].
  final String? visitId;
  final DateTime? visitedAt;

  /// Why it was skipped. Null unless [state] is [TourStopState.skipped] — or
  /// when the reason is one this build has no name for.
  final SkipReason? skipReason;

  bool get isDone => state != TourStopState.pending;

  @override
  bool operator ==(Object other) =>
      other is TourStopProgress &&
      other.spot == spot &&
      other.state == state &&
      other.planned == planned &&
      other.stopId == stopId &&
      other.spotName == spotName &&
      other.visitId == visitId &&
      other.visitedAt == visitedAt &&
      other.skipReason == skipReason;

  @override
  int get hashCode => Object.hash(
    spot,
    state,
    planned,
    stopId,
    spotName,
    visitId,
    visitedAt,
    skipReason,
  );

  @override
  String toString() =>
      'TourStopProgress($spot, ${state.name}, planned: $planned)';
}

/// A round's progress: the ordered route, plus what was added to it.
@immutable
class TourProgress {
  const TourProgress({required this.entries});

  /// The planned stops in the template's order, then the additions in the order
  /// they were visited.
  final List<TourStopProgress> entries;

  /// Buildings the template listed, however many have been reached.
  int get plannedCount => entries.where((e) => e.planned).length;

  /// Planned stops that are settled — checked or skipped, because both are
  /// answers to "have we dealt with this building".
  int get plannedDone => entries.where((e) => e.planned && e.isDone).length;

  /// Buildings visited on this round that the template did not list.
  int get addedCount => entries.where((e) => !e.planned).length;

  /// Everything planned has been settled. True for an empty route as well: a
  /// round of nothing has nothing left to do, and the finish button must not be
  /// the one thing the screen refuses.
  bool get isComplete => plannedDone == plannedCount;

  /// The next planned stop nobody has reached, or null when the route is done.
  TourStopProgress? get nextPending =>
      entries.where((e) => e.planned && !e.isDone).firstOrNull;
}

/// Derives a round's progress from its route and the visits recorded on it.
///
/// **The one derivation.** There is no `tour_run_spots` table to disagree with:
/// a stop is done because a visit says so, and every state a progress row could
/// hold — checked, skipped with a reason, added on the way — is already a visit
/// (see migration 015). A second representation would be a second thing to keep
/// in step, and the one that drifts is always the derived one.
///
/// [visits] may hold more than one visit per building: somebody walks into an
/// attic, gets sent away, comes back an hour later with the key. **The latest
/// wins**, by `visited_at`, because the question a progress list answers is
/// "where does this building stand NOW" — showing the earlier refusal after the
/// successful check would report the round as less finished than it is. A visit
/// with no timestamp sorts oldest rather than being dropped: it is still a
/// visit, and losing it would show a settled stop as pending.
///
/// [stops] is expected to arrive in the template's order (the server sorts by
/// `sort_index`) and that order is preserved as given — re-sorting here would
/// be a second opinion about what the route is.
TourProgress tourProgress({
  required List<TourStop> stops,
  required List<Visit> visits,
  Map<String, String> spotNames = const {},
}) {
  final latest = <String, Visit>{};
  for (final visit in visits) {
    final previous = latest[visit.spot];
    if (previous == null || !_isOlder(visit, previous)) {
      latest[visit.spot] = visit;
    }
  }

  final entries = <TourStopProgress>[];
  final plannedSpots = <String>{};
  for (final stop in stops) {
    // A template with the same building twice cannot exist — the collection has
    // a unique index on (tour, spot) — but a duplicate here would silently
    // count one visit twice, so the second copy is dropped rather than trusted.
    if (!plannedSpots.add(stop.spot)) continue;
    final visit = latest[stop.spot];
    entries.add(
      TourStopProgress(
        spot: stop.spot,
        state: _stateOf(visit),
        planned: true,
        stopId: stop.id,
        spotName: stop.spotName ?? spotNames[stop.spot],
        visitId: visit?.id,
        visitedAt: visit?.visitedAt,
        skipReason: visit?.skipReason,
      ),
    );
  }

  final added =
      latest.values
          .where((visit) => !plannedSpots.contains(visit.spot))
          .toList()
        ..sort(_byVisitedAt);
  for (final visit in added) {
    entries.add(
      TourStopProgress(
        spot: visit.spot,
        state: _stateOf(visit),
        planned: false,
        spotName: visit.spotName ?? spotNames[visit.spot],
        visitId: visit.id,
        visitedAt: visit.visitedAt,
        skipReason: visit.skipReason,
      ),
    );
  }

  return TourProgress(entries: entries);
}

/// The state one visit puts a stop in.
///
/// An outcome this build has no name for reads as [TourStopState.checked]: the
/// building WAS visited, and the one thing the list must not do is offer it
/// again as untouched — that is how a nest gets checked twice in one round and
/// the rhythm advances on the second reading.
TourStopState _stateOf(Visit? visit) => switch (visit?.outcome) {
  null when visit == null => TourStopState.pending,
  VisitOutcome.skipped => TourStopState.skipped,
  _ => TourStopState.checked,
};

/// Whether [a] happened before [b]. A missing timestamp counts as oldest, so a
/// visit that has one always wins over one that does not.
bool _isOlder(Visit a, Visit b) {
  final at = a.visitedAt;
  final bt = b.visitedAt;
  if (at == null) return true;
  if (bt == null) return false;
  return at.isBefore(bt);
}

int _byVisitedAt(Visit a, Visit b) => _isOlder(a, b) ? -1 : 1;
