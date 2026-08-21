import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'spots_providers.g.dart';

/// How long a search field waits for the typing to stop before asking the
/// server.
///
/// One constant for both screens that search: the list and the map run the
/// SAME query (`spot_overview`'s own search filter), so two debounce values
/// would be two different answers to "has the reader stopped typing" for one
/// question. 300 ms is the usual floor at which a fast typist stops generating
/// a request per keystroke without the field feeling laggy.
const kSpotSearchDebounce = Duration(milliseconds: 300);

/// What the Spot list currently shows for one search term.
@immutable
class SpotFeedState {
  const SpotFeedState({
    this.items = const [],
    this.cursor,
    this.loadingMore = false,
    this.pageError,
  });

  final List<SpotOverview> items;

  /// Where the next page resumes from, or null once the list is exhausted.
  final SpotOverviewCursor? cursor;

  bool get hasMore => cursor != null;

  /// A page is in flight. Separate from the provider's own `AsyncLoading`,
  /// which belongs to the FIRST page: appending must not blank the list that is
  /// already on screen.
  final bool loadingMore;

  /// Why the last page failed. Held here rather than thrown, because the only
  /// caller is a scroll listener and a listener cannot await — and a list the
  /// reader believes they have reached the bottom of is worse than one that
  /// says it stopped.
  final Object? pageError;

  /// The same rows and the same cursor, with a new tail state. Keeping the
  /// cursor is the point: a retry has to resume exactly where the attempt that
  /// failed did.
  SpotFeedState withTail({bool loadingMore = false, Object? pageError}) =>
      SpotFeedState(
        items: items,
        cursor: cursor,
        loadingMore: loadingMore,
        pageError: pageError,
      );
}

/// The Spot list for [search], optionally narrowed to one [urgency] rank:
/// most urgent first, a page at a time.
///
/// Reads `spot_overview` and nothing else. One query per page — never one per
/// row — because a list that fires a request per building is what makes this
/// app feel broken on a phone in a stairwell, and the counts and the urgency
/// rank a row draws come from the view anyway.
///
/// The rank is part of the provider's key, so switching filters is a new query
/// and not a mutation of the one on screen — the page that was loading for
/// "everything" cannot land in the list for "overdue".
@riverpod
class SpotFeed extends _$SpotFeed {
  @override
  Future<SpotFeedState> build(String search, SpotUrgency? urgency) async {
    final repo = await ref.watch(spotOverviewRepositoryProvider.future);
    final page = await repo.dueFirst(query: search, urgency: urgency?.rank);
    return SpotFeedState(items: page.items, cursor: page.cursor);
  }

  /// Appends the next page. Safe to call repeatedly — a no-op while a page is
  /// in flight, once the list is exhausted, or after a page failed.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null ||
        !current.hasMore ||
        current.loadingMore ||
        current.pageError != null) {
      return;
    }
    await _appendPage(current);
  }

  /// Tries the page that failed again, from the same cursor.
  Future<void> retryPage() async {
    final current = state.value;
    if (current == null || current.pageError == null) return;
    await _appendPage(current);
  }

  Future<void> _appendPage(SpotFeedState current) async {
    state = AsyncData(current.withTail(loadingMore: true));
    try {
      final repo = await ref.read(spotOverviewRepositoryProvider.future);
      final next = await repo.dueFirst(
        query: search,
        urgency: urgency?.rank,
        after: current.cursor,
      );
      state = AsyncData(
        SpotFeedState(
          items: [...current.items, ...next.items],
          cursor: next.cursor,
        ),
      );
    } on Object catch (error) {
      // Keep what is on screen, and keep the cursor so the retry resumes
      // exactly where this attempt did — no gap, no duplicates.
      state = AsyncData(current.withTail(pageError: error));
    }
  }
}

/// One Spot's full record, for the detail screen.
///
/// Not `spot_overview`: the view carries what a row and a pin draw, so the
/// note, the pause reason and the closing date are only on the collection.
@riverpod
Future<Spot> spot(Ref ref, String id) async {
  final repo = await ref.watch(spotsRepositoryProvider.future);
  return repo.getOne(id);
}

/// One Spot's contacts, the ones worth ringing first at the top.
@riverpod
Future<List<SpotContact>> spotContacts(Ref ref, String spotId) async {
  final repo = await ref.watch(spotContactsRepositoryProvider.future);
  return repo.forSpot(spotId);
}

/// Every Spot in the org, unpaged.
///
/// Two screens need the whole set rather than a page: the map, because one that
/// drew only the first page would hide pins the reader is looking straight at,
/// and the dashboard, whose tiles are counts over all of them. They share this
/// one read — the map opening after the dashboard costs no request at all.
/// `search('')` is the view's own answer for it: the whole set, by name.
///
/// One query for the whole screen. A map that fired a request per pin is what
/// makes an app feel broken on a phone in a stairwell, and the counts and the
/// urgency rank a pin needs are in the view already.
@riverpod
Future<List<SpotOverview>> allSpots(Ref ref) async {
  final repo = await ref.watch(spotOverviewRepositoryProvider.future);
  return repo.search('');
}

/// Every Spot matching [search], unpaged — the map's read.
///
/// Unpaged for the same reason [allSpots] is: the map draws all of them, and a
/// search that returned only the first page would hide a pin the reader is
/// looking straight at.
///
/// The empty query delegates to [allSpots] rather than repeating its request,
/// so opening the map after the dashboard still costs nothing — and the two
/// screens cannot disagree about what "everything" is. A non-empty query is its
/// own read because the matching itself is the server's: the columns a term is
/// tried against live in `spot_overview`'s search filter, and a Dart
/// reimplementation would be a second definition of "matches" that drifts from
/// the list's.
@riverpod
Future<List<SpotOverview>> spotsMatching(Ref ref, String search) async {
  if (search.trim().isEmpty) return ref.watch(allSpotsProvider.future);
  final repo = await ref.watch(spotOverviewRepositoryProvider.future);
  return repo.search(search);
}

/// How many Spots sit at each urgency rank.
///
/// A pure count over rows already loaded, not a query per tile: three
/// `?perPage=1` requests for three `totalItems` would be three round trips for
/// what one list answers, and they could disagree with each other while
/// somebody is writing.
///
/// A rank with nothing in it is absent from the map rather than present as
/// zero — the caller decides whether "no overdue Spots" is worth a tile, and
/// [SpotUrgency.values] is the only honest list of what could appear.
Map<SpotUrgency, int> countByUrgency(List<SpotOverview> rows) {
  final counts = <SpotUrgency, int>{};
  for (final row in rows) {
    // A rank this build has no name for is left out on purpose: a tile that
    // silently folded it into the nearest known rank would state something
    // untrue about how much work is waiting.
    if (row.level case final level?) {
      counts[level] = (counts[level] ?? 0) + 1;
    }
  }
  return counts;
}

/// Invalidates every read that draws a Spot in a list, on the map or as a
/// count.
///
/// One call, because there are three such reads now and the tour screens will
/// add a fourth. The map is the reason it exists: it arrived as a SECOND reader
/// of the same rows while five write sites went on invalidating only the list —
/// so a Spot created from the map's own button did not appear on the map until
/// the screen was left and re-entered. The dashboard's tiles read
/// [allSpotsProvider] too, which is why they cannot drift out of this.
void invalidateSpotViews(WidgetRef ref) {
  ref
    ..invalidate(spotFeedProvider)
    ..invalidate(allSpotsProvider)
    // The whole family: a reader who searched on the map is looking at
    // `spotsMatching('bahnhof')`, and refreshing only the unfiltered read would
    // leave the Spot they just created off the screen it was created from —
    // which is the exact bug this function was written for.
    ..invalidate(spotsMatchingProvider);
}
