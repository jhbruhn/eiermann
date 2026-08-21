import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'history_providers.g.dart';

/// How far back the dashboard's Funde number looks.
///
/// A window and not an all-time total, because the number has to mean "is
/// something going on right now". An all-time count only ever grows, so it
/// stops carrying information after the first season — and a tile nobody reads
/// is worse than no tile.
const kFindingsWindow = Duration(days: 30);

/// One visit and everything recorded on it.
///
/// The unit of the dossier's chronology, and the reason the chronology is ONE
/// list rather than three sections: a check and a Fund only exist because
/// somebody was at the building, and separating them from that trip makes the
/// reader join them by date in their head. federfall's rule — one consistent
/// view instead of fragmented sections — is this class.
@immutable
class VisitEntry {
  const VisitEntry({
    required this.visit,
    this.checks = const [],
    this.findings = const [],
  });

  final Visit visit;
  final List<NestCheck> checks;
  final List<Finding> findings;

  /// Real eggs this visit took out of the building — the programme's metric.
  int get removedReal =>
      checks.fold(0, (sum, check) => sum + check.removedReal);

  /// Dummies it placed.
  int get addedDummy => checks.fold(0, (sum, check) => sum + check.addedDummy);

  /// The checks that created a Nachkontrolle.
  Iterable<NestCheck> get halfClutches =>
      checks.where((check) => check.state == CheckState.partial);
}

/// What the dossier's chronology currently shows.
@immutable
class SpotHistoryState {
  const SpotHistoryState({
    this.entries = const [],
    this.cursor,
    this.loadingMore = false,
    this.pageError,
  });

  final List<VisitEntry> entries;

  /// Where the next page resumes from, or null once the history is exhausted.
  final PbCursor? cursor;

  bool get hasMore => cursor != null;

  /// A page is in flight. Separate from the provider's own `AsyncLoading`,
  /// which belongs to the FIRST page: appending must not blank the chronology
  /// already on screen.
  final bool loadingMore;

  /// Why the last page failed. Held rather than thrown: the only caller is a
  /// scroll listener, and a reader who believes they have reached the beginning
  /// of the history is worse off than one told the list stopped.
  final Object? pageError;

  SpotHistoryState withTail({bool loadingMore = false, Object? pageError}) =>
      SpotHistoryState(
        entries: entries,
        cursor: cursor,
        loadingMore: loadingMore,
        pageError: pageError,
      );
}

/// The chronology of one building: visits newest first, each with its checks
/// and its Funde.
///
/// **Three requests per page, never three per row.** The visits are
/// keyset-paged on `visited_at`, and the checks and Funde of that whole page
/// are fetched in one request each with an OR-of-ids filter. A chronology that
/// fetched per visit would be twenty requests for one screen, which is what
/// makes an app feel broken on a phone in a stairwell.
///
/// Paged by the VISITS and not by a merged timeline across three collections.
/// Every check and every Fund belongs to a visit, so nothing can fall outside a
/// page — and merging three independently paged streams is where the bugs that
/// silently drop rows live.
///
/// What is NOT here: the phase changes. There is no history of them to read —
/// the Spot record holds only its current phase, its closing date and its
/// reason. They join this list when there is an audit trail to read them from
/// (`eiermann-uwd.3`), and until then the dossier header carries them.
@riverpod
class SpotHistory extends _$SpotHistory {
  @override
  Future<SpotHistoryState> build(String spotId) async {
    final page = await _fetch();
    return SpotHistoryState(entries: page.$1, cursor: page.$2);
  }

  /// Appends the next page. Safe to call repeatedly — a no-op while a page is
  /// in flight, once the history is exhausted, or after a page failed.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null ||
        !current.hasMore ||
        current.loadingMore ||
        current.pageError != null) {
      return;
    }
    state = AsyncData(current.withTail(loadingMore: true));
    try {
      final next = await _fetch(after: current.cursor);
      state = AsyncData(
        SpotHistoryState(
          entries: [...current.entries, ...next.$1],
          cursor: next.$2,
        ),
      );
    } on Object catch (error) {
      // Keep what is on screen AND the cursor, so the retry resumes exactly
      // where this attempt did — no gap, no duplicates.
      state = AsyncData(current.withTail(pageError: error));
    }
  }

  /// Tries the page that failed again, from the same cursor.
  Future<void> retryPage() async {
    final current = state.value;
    if (current == null || current.pageError == null) return;
    state = AsyncData(current.withTail(loadingMore: true));
    try {
      final next = await _fetch(after: current.cursor);
      state = AsyncData(
        SpotHistoryState(
          entries: [...current.entries, ...next.$1],
          cursor: next.$2,
        ),
      );
    } on Object catch (error) {
      state = AsyncData(current.withTail(pageError: error));
    }
  }

  /// One page of visits, with their checks and Funde already attached.
  Future<(List<VisitEntry>, PbCursor?)> _fetch({PbCursor? after}) async {
    final visitsRepo = await ref.read(visitHistoryRepositoryProvider.future);
    final page = await visitsRepo.pageForSpot(spotId, after: after);
    final ids = [for (final visit in page.items) visit.id];
    if (ids.isEmpty) return (const <VisitEntry>[], page.cursor);

    final checksRepo = await ref.read(nestChecksRepositoryProvider.future);
    final findingsRepo = await ref.read(findingsRepositoryProvider.future);
    // Concurrently: the two reads are independent, and a chronology that waited
    // for one before starting the other is twice the latency for no reason.
    final (checks, findings) = await (
      checksRepo.forVisits(ids),
      findingsRepo.forVisits(ids),
    ).wait;

    final checksByVisit = <String, List<NestCheck>>{};
    for (final check in checks) {
      (checksByVisit[check.visit ?? ''] ??= []).add(check);
    }
    final findingsByVisit = <String, List<Finding>>{};
    for (final finding in findings) {
      (findingsByVisit[finding.visit ?? ''] ??= []).add(finding);
    }

    return (
      [
        for (final visit in page.items)
          VisitEntry(
            visit: visit,
            checks: checksByVisit[visit.id] ?? const [],
            findings: findingsByVisit[visit.id] ?? const [],
          ),
      ],
      page.cursor,
    );
  }
}

/// How many Funde the org recorded in the last [kFindingsWindow].
///
/// Counted server-side: the dashboard wants one number, and pulling every row
/// over the wire to call `.length` on it is the same request with a payload
/// nobody reads.
///
/// The window is computed from LOCAL midnight, which is the boundary a reader
/// means by "in the last thirty days" — PocketBase stores UTC, and a window
/// built from a raw `DateTime.now()` would slide by the time of day.
@riverpod
Future<int> recentFindingsCount(Ref ref) async {
  final repo = await ref.watch(findingsRepositoryProvider.future);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return repo.countSince(today.subtract(kFindingsWindow));
}

/// What the Funde list currently shows.
@immutable
class FindingsFeedState {
  const FindingsFeedState({
    this.items = const [],
    this.cursor,
    this.loadingMore = false,
    this.pageError,
  });

  final List<Finding> items;
  final PbCursor? cursor;

  bool get hasMore => cursor != null;
  final bool loadingMore;
  final Object? pageError;

  FindingsFeedState withTail({bool loadingMore = false, Object? pageError}) =>
      FindingsFeedState(
        items: items,
        cursor: cursor,
        loadingMore: loadingMore,
        pageError: pageError,
      );
}

/// Every Fund in the org, newest first — where the dashboard number leads.
///
/// A number on the dashboard has to be a way IN, not a dead end: "7 Funde" that
/// cannot be opened is a fact nobody can act on. This is the list it opens, and
/// every row leads on to the building it was found at.
@riverpod
class FindingsFeed extends _$FindingsFeed {
  @override
  Future<FindingsFeedState> build() async {
    final repo = await ref.watch(findingsRepositoryProvider.future);
    final page = await repo.pageRecent();
    return FindingsFeedState(items: page.items, cursor: page.cursor);
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null ||
        !current.hasMore ||
        current.loadingMore ||
        current.pageError != null) {
      return;
    }
    await _append(current);
  }

  Future<void> retryPage() async {
    final current = state.value;
    if (current == null || current.pageError == null) return;
    await _append(current);
  }

  Future<void> _append(FindingsFeedState current) async {
    state = AsyncData(current.withTail(loadingMore: true));
    try {
      final repo = await ref.read(findingsRepositoryProvider.future);
      final next = await repo.pageRecent(after: current.cursor);
      state = AsyncData(
        FindingsFeedState(
          items: [...current.items, ...next.items],
          cursor: next.cursor,
        ),
      );
    } on Object catch (error) {
      state = AsyncData(current.withTail(pageError: error));
    }
  }
}

/// Invalidates every reader of the recorded history.
///
/// Called after a visit lands, because a visit IS a history entry — and a
/// chronology that still ends at the previous visit reads as a write that did
/// not happen.
void invalidateHistoryViews(WidgetRef ref) {
  ref
    ..invalidate(spotHistoryProvider)
    ..invalidate(recentFindingsCountProvider)
    ..invalidate(findingsFeedProvider);
}
