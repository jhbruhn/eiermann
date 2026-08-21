import 'package:eiermann/features/home/sign_out_action.dart';
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

/// The first screen after signing in: how much work is waiting, as four
/// numbers.
///
/// Each tile is a way IN — it opens the Spot list narrowed to that rank, which
/// is why a number is never a dead end. A tile at zero loses its tap: a
/// promised destination that turns out to be an empty list is worse than a
/// number that plainly reports nothing to do.
///
/// The blocks the concept asks for at the very top — open Halbgelege first —
/// need nests to be due and arrive with Phase 04 (eiermann-jbk). These four
/// ranks are what `spot_overview` can answer today, and they answer it without
/// a single query of their own: the counts are a pass over the same unpaged
/// read the map draws its pins from.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  /// The ranks worth a tile, in the order they matter.
  ///
  /// Not every rank: `inRhythm`, `paused` and `closed` are the absence of work,
  /// and a tile counting them would compete for attention with the three that
  /// are asking for a visit. `prospect` earns its place because it is work of a
  /// different kind — a conversation, not a round — and a group that forgets
  /// its running Erkundungen loses buildings it had already half won.
  static const List<SpotUrgency> _ranks = [
    SpotUrgency.overdue,
    SpotUrgency.dueToday,
    SpotUrgency.dueThisWeek,
    SpotUrgency.prospect,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final spots = ref.watch(allSpotsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.dashboardTitle),
        actions: const [SignOutAction()],
      ),
      body: AsyncValueView(
        value: spots,
        onRetry: () => ref.invalidate(allSpotsProvider),
        data: (rows) => _Tiles(rows: rows),
      ),
    );
  }
}

class _Tiles extends ConsumerWidget {
  const _Tiles({required this.rows});

  final List<SpotOverview> rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;

    if (rows.isEmpty) {
      // No Spots at all is a different screen from no work: the group has not
      // started, and the only useful thing here is the way to start.
      return EmptyView(
        icon: Icons.home_work_outlined,
        title: l10n.spotsEmptyTitle,
        message: l10n.spotsEmptyMessage,
        actionLabel: l10n.spotsEmptyAction,
        actionIcon: Icons.add,
        onAction: () => showSpotSheet(context),
      );
    }

    final counts = countByUrgency(rows);
    return RefreshIndicator(
      onRefresh: () => ref.refresh(allSpotsProvider.future),
      child: ListView(
        // Always scrollable, so pull-to-refresh works on a grid that fits.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(ZugvogelSpacing.md),
        children: [
          ContentBounds(
            child: KpiGrid([
              for (final rank in DashboardScreen._ranks)
                _tile(context, rank, counts[rank] ?? 0),
            ]),
          ),
        ],
      ),
    );
  }

  KpiCard _tile(BuildContext context, SpotUrgency rank, int count) {
    final l10n = context.l10n;
    return KpiCard(
      icon: spotUrgencyIcon(rank),
      label: spotUrgencyLabel(l10n, rank),
      value: '$count',
      // Zero is a real reading, and it keeps its tile so the grid does not
      // reflow every time a Spot is visited. It loses the chevron instead.
      onTap: count == 0
          ? null
          // The Erkundungen go to the FUNNEL, not to a filtered list. They are
          // work of a different kind, and the question they raise — bei wem
          // hängt es? — is one a flat list of buildings cannot answer. The rank
          // and the phase agree exactly here: the view ranks a prospect 4, and
          // a paused one ranks as paused.
          : () => context.push(
              rank == SpotUrgency.prospect
                  ? Routes.prospects
                  : Routes.spotsByUrgency(rank),
            ),
    );
  }
}
