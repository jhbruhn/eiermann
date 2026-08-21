import 'dart:async';

import 'package:eiermann/features/spots/spot_labels.dart';
import 'package:eiermann/features/spots/spot_sheet.dart';
import 'package:eiermann/features/spots/spots_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/routing/router.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// How long the search field waits for the typing to stop before asking the
/// server. The search is a query, not a pass over a local list.
const _searchDebounce = Duration(milliseconds: 300);

/// The Spot list — every building, most urgent first.
///
/// Reads `spot_overview` and ONLY that: one query per page, never one per row.
/// The view already carries the contact counts and the urgency rank, so a row
/// costs nothing extra to draw.
///
/// The list is a body, not a screen: `SpotsScreen` hosts it as a destination of
/// the nav shell and owns the app bar.
class SpotsList extends ConsumerStatefulWidget {
  const SpotsList({this.urgency, super.key});

  /// Show only this rank. Comes from the route (see `Routes.spotsByUrgency`),
  /// which is why clearing the chip is a navigation and not a `setState`: the
  /// location is what a restore and a back gesture read, so it has to be the
  /// one place the filter is written down.
  final SpotUrgency? urgency;

  @override
  ConsumerState<SpotsList> createState() => _SpotsListState();
}

class _SpotsListState extends ConsumerState<SpotsList> {
  final _searchController = TextEditingController();
  final _scroll = ScrollController();
  String _query = '';
  Timer? _searchTimer;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _scroll.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String text) {
    _searchTimer?.cancel();
    _searchTimer = Timer(_searchDebounce, () {
      if (mounted) setState(() => _query = text);
    });
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    // Within a screenful of the bottom. `loadMore` is a no-op while a page is
    // in flight, so firing this on every scroll frame is safe. `PagedListTail`
    // asks as well, for the list too short to scroll at all.
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 600) {
      unawaited(
        ref.read(spotFeedProvider(_query, widget.urgency).notifier).loadMore(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final feed = ref.watch(spotFeedProvider(_query, widget.urgency));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(ZugvogelSpacing.md),
          child: TextField(
            controller: _searchController,
            onChanged: _onSearchChanged,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: l10n.spotsSearchHint,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        // The filter has to be VISIBLE or the list lies: a reader who arrived
        // from a dashboard tile, then searched, would otherwise read a short
        // result as "no such building" when it is "no such building among the
        // overdue ones".
        if (widget.urgency case final rank?)
          Padding(
            padding: const EdgeInsets.only(
              left: ZugvogelSpacing.md,
              right: ZugvogelSpacing.md,
              bottom: ZugvogelSpacing.md,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: InputChip(
                avatar: Icon(
                  spotUrgencyIcon(rank),
                  color: spotUrgencyColor(context, rank),
                ),
                label: Text(spotUrgencyLabel(l10n, rank)),
                onDeleted: () => context.go(Routes.spots),
                deleteButtonTooltipMessage: l10n.spotsFilterClear,
              ),
            ),
          ),
        const Divider(height: 1),
        // Inside the Column, not around it: the search field has to stay put
        // while the results below it load, or typing loses focus on every
        // request.
        Expanded(
          child: AsyncValueView<SpotFeedState>(
            value: feed,
            onRetry: () =>
                ref.invalidate(spotFeedProvider(_query, widget.urgency)),
            data: _results,
          ),
        ),
      ],
    );
  }

  Widget _results(SpotFeedState state) {
    final l10n = context.l10n;
    if (state.items.isEmpty) {
      // Which emptiness this is can no longer be read off the loaded rows — the
      // server sent only what matched. A search or a rank filter says so
      // itself; offering "add the first Spot" while a filter is on would call
      // an org full of buildings empty.
      return _query.trim().isEmpty && widget.urgency == null
          ? EmptyView(
              icon: Icons.home_work_outlined,
              title: l10n.spotsEmptyTitle,
              message: l10n.spotsEmptyMessage,
              actionLabel: l10n.spotsEmptyAction,
              actionIcon: Icons.add,
              onAction: () => showSpotSheet(context),
            )
          : EmptyView(
              message: _query.trim().isEmpty
                  ? l10n.spotsFilterEmpty
                  : l10n.spotsNoMatches,
            );
    }
    return RefreshIndicator(
      onRefresh: () =>
          ref.refresh(spotFeedProvider(_query, widget.urgency).future),
      child: ContentBounds(
        child: ListView.builder(
          controller: _scroll,
          // Always scrollable, so pull-to-refresh works on a short list.
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: state.items.length + (state.hasMore ? 1 : 0),
          itemBuilder: (context, i) {
            if (i >= state.items.length) {
              return PagedListTail(
                error: state.pageError,
                onLoad: () => unawaited(
                  ref
                      .read(spotFeedProvider(_query, widget.urgency).notifier)
                      .loadMore(),
                ),
                onRetry: () => unawaited(
                  ref
                      .read(spotFeedProvider(_query, widget.urgency).notifier)
                      .retryPage(),
                ),
              );
            }
            return SpotTile(state.items[i]);
          },
        ),
      ),
    );
  }
}

/// One Spot in the list: what it is called, where it is, and why it is here.
class SpotTile extends StatelessWidget {
  const SpotTile(this.row, {super.key});

  final SpotOverview row;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final materialL10n = MaterialLocalizations.of(context);
    final level = row.level;

    // The rank carries a colour AND words. The words are not a fallback: a red
    // row says nothing to a colour-blind carer, and colour as the only carrier
    // of meaning fails WCAG 1.4.1.
    final urgency = Row(
      children: [
        Icon(
          spotUrgencyIcon(level),
          size: 16,
          color: spotUrgencyColor(context, level),
        ),
        const SizedBox(width: ZugvogelSpacing.xs),
        Flexible(
          child: Text(
            [
              spotUrgencyLabel(l10n, level),
              if (row.nextDueAt != null)
                l10n.spotDueOn(formatLocalDate(materialL10n, row.nextDueAt)),
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: spotUrgencyColor(context, level),
              fontWeight: level == SpotUrgency.overdue ? FontWeight.bold : null,
            ),
          ),
        ),
      ],
    );

    return ListTile(
      isThreeLine: true,
      title: Text(row.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (row.addressLine case final address?) Text(address),
          const SizedBox(height: ZugvogelSpacing.xs),
          urgency,
          const SizedBox(height: ZugvogelSpacing.xs),
          Row(
            children: [
              TagChip(label: spotPhaseLabel(l10n, row.phase)),
              const SizedBox(width: ZugvogelSpacing.sm),
              // Zero is a real and useful reading here — a building with no
              // number to ring is a handover gap — so the count is always
              // spelled out rather than hidden when it is nothing.
              Text(
                l10n.spotContactCount(row.contactCount),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push(Routes.spotDetail(row.id)),
    );
  }
}
