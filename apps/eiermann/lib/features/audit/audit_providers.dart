import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'audit_providers.g.dart';

/// What the log screen currently shows.
@immutable
class AuditLogState {
  const AuditLogState({
    this.entries = const [],
    this.cursor,
    this.loadingMore = false,
    this.pageError,
  });

  final List<AuditEntry> entries;

  /// Where the next page resumes from, or null once the log is exhausted.
  final PbCursor? cursor;

  bool get hasMore => cursor != null;

  /// A page is in flight. Separate from the provider's own `AsyncLoading`,
  /// which belongs to the FIRST page: appending must not blank what is already
  /// on screen.
  final bool loadingMore;

  /// Why the last page failed. Held rather than thrown — the only caller is a
  /// scroll listener, and a reader who believes they have reached the beginning
  /// of the log is worse off than one told the list stopped.
  ///
  /// This matters more here than anywhere else in the app: an audit log is read
  /// in order to CITE it, so a silent end is a silently incomplete answer.
  final Object? pageError;

  AuditLogState withTail({bool loadingMore = false, Object? pageError}) =>
      AuditLogState(
        entries: entries,
        cursor: cursor,
        loadingMore: loadingMore,
        pageError: pageError,
      );
}

/// The org's log, newest first, or one target's slice of it.
///
/// Pass a target id to narrow it — which still answers for a Spot that has been
/// deleted, because `target` is a stored TEXT id rather than a relation.
///
/// KEYSET paged, never `?page=`. This table only ever grows, and it grows at
/// exactly the end being read from: an offset page would skip rows as new ones
/// arrive, and an audit log that silently omits an entry is worse than no audit
/// log at all.
@riverpod
class AuditLog extends _$AuditLog {
  @override
  Future<AuditLogState> build(String? targetId) async {
    final page = await _fetch();
    return AuditLogState(entries: page.items, cursor: page.cursor);
  }

  /// Appends the next page. Safe to call repeatedly — a no-op while a page is
  /// in flight, once the log is exhausted, or after a page failed.
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

  /// Tries the page that failed again, from the same cursor.
  Future<void> retryPage() async {
    final current = state.value;
    if (current == null || current.pageError == null) return;
    await _append(current);
  }

  Future<void> _append(AuditLogState current) async {
    state = AsyncData(current.withTail(loadingMore: true));
    try {
      final next = await _fetch(after: current.cursor);
      state = AsyncData(
        AuditLogState(
          entries: [...current.entries, ...next.items],
          cursor: next.cursor,
        ),
      );
    } on Object catch (error) {
      // Keep what is on screen AND the cursor, so a retry resumes exactly where
      // this attempt did — no gap, no duplicates.
      state = AsyncData(current.withTail(pageError: error));
    }
  }

  Future<PbPage<AuditEntry>> _fetch({PbCursor? after}) async {
    final repo = await ref.read(auditRepositoryProvider.future);
    final target = targetId;
    return target == null
        ? repo.pageOfLog(after: after)
        : repo.pageForTarget(target, after: after);
  }
}
