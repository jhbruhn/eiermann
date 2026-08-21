import 'dart:async';

import 'package:eiermann/features/findings/finding_labels.dart';
import 'package:eiermann/features/history/history_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/routing/router.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Every Fund in the organisation, newest first.
///
/// Where the dashboard's Funde number leads, and the reason it may be a number
/// at all: a count nobody can open is a fact nobody can act on. Every row leads
/// on to the building it was found at, so this list is never a dead end either.
///
/// It spans buildings, which is why the BUILDING leads each row. A list of
/// "Toter Vogel · Dohle" repeated eleven times answers nothing; the question
/// somebody brings here is where.
class FindingsScreen extends ConsumerStatefulWidget {
  const FindingsScreen({super.key});

  @override
  ConsumerState<FindingsScreen> createState() => _FindingsScreenState();
}

class _FindingsScreenState extends ConsumerState<FindingsScreen> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    // Within a screenful of the bottom. `loadMore` is a no-op while a page is
    // in flight, so firing on every scroll frame is safe; `PagedListTail` asks
    // as well, for the list too short to scroll at all.
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 600) {
      unawaited(ref.read(findingsFeedProvider.notifier).loadMore());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final feed = ref.watch(findingsFeedProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.findingsTitle)),
      body: AsyncValueView<FindingsFeedState>(
        value: feed,
        onRetry: () => ref.invalidate(findingsFeedProvider),
        data: (state) => state.items.isEmpty
            ? EmptyView(
                icon: Icons.search_off,
                title: l10n.findingsFeedEmptyTitle,
                message: l10n.findingsFeedEmptyMessage,
              )
            : RefreshIndicator(
                onRefresh: () => ref.refresh(findingsFeedProvider.future),
                child: ContentBounds(
                  child: ListView.builder(
                    controller: _scroll,
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: state.items.length + (state.hasMore ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i >= state.items.length) {
                        return PagedListTail(
                          error: state.pageError,
                          onLoad: () => unawaited(
                            ref.read(findingsFeedProvider.notifier).loadMore(),
                          ),
                          onRetry: () => unawaited(
                            ref.read(findingsFeedProvider.notifier).retryPage(),
                          ),
                        );
                      }
                      return FindingTile(state.items[i]);
                    },
                  ),
                ),
              ),
      ),
    );
  }
}

/// One Fund in a list that spans buildings.
class FindingTile extends StatelessWidget {
  const FindingTile(this.finding, {super.key});

  final Finding finding;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final materialL10n = MaterialLocalizations.of(context);
    final when = finding.foundAt;

    return ListTile(
      leading: Icon(
        findingKindIcon(finding.kind),
        color: findingKindColor(context, finding.kind),
      ),
      // The building first: it is what decides whether this matters today. The
      // expand is what makes the name available at all — an id with no label
      // next to it is a bug in this app.
      title: Text(
        finding.spotName ?? l10n.findingsUnknownSpot,
        style: theme.textTheme.titleSmall,
      ),
      subtitle: Text(
        [
          findingSummary(
            l10n,
            finding.kind,
            count: finding.count,
            speciesLabel: finding.speciesLabel,
            nestLabel: finding.nestLabel,
          ),
          if (when != null) formatLocalDate(materialL10n, when),
          ?finding.authorName,
        ].join(' · '),
        style: theme.textTheme.bodySmall,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push(Routes.spotDetail(finding.spot)),
    );
  }
}
