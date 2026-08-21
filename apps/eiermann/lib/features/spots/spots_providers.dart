import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'spots_providers.g.dart';

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

/// The Spot list for [search]: most urgent first, a page at a time.
///
/// Reads `spot_overview` and nothing else. One query per page — never one per
/// row — because a list that fires a request per building is what makes this
/// app feel broken on a phone in a stairwell, and the counts and the urgency
/// rank a row draws come from the view anyway.
@riverpod
class SpotFeed extends _$SpotFeed {
  @override
  Future<SpotFeedState> build(String search) async {
    final repo = await ref.watch(spotOverviewRepositoryProvider.future);
    final page = await repo.dueFirst(query: search);
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
      final next = await repo.dueFirst(query: search, after: current.cursor);
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

/// Every Spot in the org, for the map.
///
/// Unpaged, and that is the difference from [SpotFeed]: a list can stop at
/// fifty and load more on scroll, but a map that drew only the first page would
/// hide pins the reader is looking straight at. `search('')` is the view's own
/// answer for this — the whole set, by name.
///
/// One query for the whole screen. A map that fired a request per pin is what
/// makes an app feel broken on a phone in a stairwell, and the counts and the
/// urgency rank a pin needs are in the view already.
@riverpod
Future<List<SpotOverview>> spotPins(Ref ref) async {
  final repo = await ref.watch(spotOverviewRepositoryProvider.future);
  return repo.search('');
}
