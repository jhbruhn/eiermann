import 'package:eiermann/core/auth/roles.dart';
import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/features/history/history_providers.dart';
import 'package:eiermann/features/home/sign_out_action.dart';
import 'package:eiermann/features/spots/spot_labels.dart';
import 'package:eiermann/features/spots/spot_sheet.dart';
import 'package:eiermann/features/spots/spots_providers.dart';
import 'package:eiermann/features/tours/tours_screen.dart';
import 'package:eiermann/features/visits/visits_providers.dart';
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
/// **Open Halbgelege sit above every count**, and that is the concept's
/// ordering, not a layout preference: out of a half clutch a chick hatches in
/// days, so it is the one deadline here that a week's delay ruins. A number
/// counting them among the others would put a four-day window next to a
/// four-week one and let the reader sort it out.
///
/// The four counts below it come from `spot_overview` without a query of their
/// own — they are a pass over the same unpaged read the map draws its pins
/// from. The Halbgelege block is the one extra read on this screen.
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
    SpotUrgency.dueSoon,
    SpotUrgency.prospect,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final spots = ref.watch(allSpotsProvider);
    // Only the coordination gets the administration menu. Not a security
    // boundary — the server holds those — but a member who found the roster
    // could only look at it, and a menu entry leading to a screen whose every
    // control is greyed out reads as a broken app rather than as a permission.
    final mayAdminister =
        ref.watch(currentUserProvider).value?.role?.canAdminister ?? false;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.dashboardTitle),
        actions: [
          // The way to the figures and to the exports. Here rather than as a
          // fifth nav destination: this is what somebody opens when a
          // permission is up for renewal or a funder asks what the year came to
          // — a monthly errand, not a place to be between two buildings.
          IconButton(
            icon: const Icon(Icons.insights_outlined),
            tooltip: l10n.statsTitle,
            onPressed: () => context.push(Routes.statistics),
          ),
          if (mayAdminister) const _AdminMenu(),
          const SignOutAction(),
        ],
      ),
      body: AsyncValueView(
        value: spots,
        onRetry: () => ref.invalidate(allSpotsProvider),
        data: (rows) => _Tiles(rows: rows),
      ),
    );
  }
}

/// The coordination's errands, behind one icon.
///
/// A menu rather than an icon each: these are things somebody does a handful of
/// times a year — let a new volunteer in, adjust the rhythm after a season,
/// look up who changed a phase. Three permanent app-bar icons would give them
/// the same weight as the work itself.
class _AdminMenu extends StatelessWidget {
  const _AdminMenu();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return PopupMenuButton<String>(
      icon: const Icon(Icons.admin_panel_settings_outlined),
      tooltip: l10n.adminMenuTooltip,
      onSelected: (route) => context.push(route),
      itemBuilder: (context) => [
        PopupMenuItem(
          value: Routes.team,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.groups_outlined),
            title: Text(l10n.teamTitle),
          ),
        ),
        PopupMenuItem(
          value: Routes.rhythmSettings,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.timelapse_outlined),
            title: Text(l10n.rhythmSettingsTitle),
          ),
        ),
        PopupMenuItem(
          value: Routes.audit,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.history),
            title: Text(l10n.auditTitle),
          ),
        ),
      ],
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
    // `.value`, so a failed or still-loading read draws a dash rather than an
    // error: this tile sits beside four that came from a DIFFERENT request, and
    // one server hiccup must not make the grid look broken.
    final findings = ref.watch(recentFindingsCountProvider).value;
    return RefreshIndicator(
      onRefresh: () => ref.refresh(allSpotsProvider.future),
      child: ListView(
        // Always scrollable, so pull-to-refresh works on a grid that fits.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(ZugvogelSpacing.md),
        children: [
          // An open round sits above even the Halbgelege, and that is not a
          // ranking of importance — it is a ranking of INTERRUPTION. Somebody
          // who left a round half-walked and reopened the app is in the middle
          // of something, and the first thing they need is the way back into
          // it. The Halbgelege below it is the loudest DEADLINE; this is the
          // loudest unfinished thing.
          const ContentBounds(child: OpenRunCard()),
          const ContentBounds(child: _HalfClutchBlock()),
          const SizedBox(height: ZugvogelSpacing.md),
          ContentBounds(
            child: KpiGrid([
              for (final rank in DashboardScreen._ranks)
                _tile(context, rank, counts[rank] ?? 0),
              // The fifth tile is not a rank and does not come from
              // `spot_overview`: it is a count of RECORDED EVENTS over a
              // window, and the one number here that says something is going
              // ON rather than something being due. It sits last because the
              // four above it are work waiting; this one is work done.
              _findingsTile(context, findings),
            ]),
          ),
        ],
      ),
    );
  }

  /// The Funde of the last weeks, as one number.
  ///
  /// A window and not an all-time total: an all-time count only grows, so it
  /// stops carrying information after the first season, and a tile nobody reads
  /// is worse than no tile. Thirty days is short enough that a change in it
  /// means something.
  ///
  /// It taps through to the Funde list, because a number on this screen has to
  /// be a way IN — "7 Funde" that cannot be opened is a fact nobody can act on.
  /// At zero it loses the tap, like every other tile here. So does a count that
  /// could not be read: there is no list to promise.
  KpiCard _findingsTile(BuildContext context, int? count) {
    final l10n = context.l10n;
    return KpiCard(
      icon: Icons.pest_control_outlined,
      label: l10n.dashboardFindingsLabel,
      value: count == null ? '—' : '$count',
      onTap: count == null || count == 0
          ? null
          : () => context.push(Routes.findings),
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

/// The open Nachkontrollen, earliest first — the top of the dashboard.
///
/// Rows and not a count, deliberately. A number would be one more tile to
/// compare; what somebody needs is WHICH nest in WHICH building, because that
/// is a decision about today's route. Each row leads to the dossier, so the
/// block is never a dead end.
///
/// A failed read renders as nothing rather than as an error banner: this block
/// sits above the counts, and a server hiccup must not push the whole dashboard
/// off the screen. The counts below carry their own error state.
class _HalfClutchBlock extends ConsumerWidget {
  const _HalfClutchBlock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final rows = ref.watch(openFollowUpsProvider).value;
    // Nothing open is worth saying out loud once the block exists — an absent
    // block would read as "not loaded".
    if (rows == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const IconChip(Icons.hourglass_bottom),
            const SizedBox(width: ZugvogelSpacing.md),
            Expanded(
              child: Text(
                l10n.dashboardHalfClutchTitle,
                style: theme.textTheme.titleMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: ZugvogelSpacing.sm),
        if (rows.isEmpty)
          Text(
            l10n.dashboardHalfClutchEmpty,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else
          for (final followUp in rows) _FollowUpTile(followUp),
      ],
    );
  }
}

/// One open Nachkontrolle: which nest, which building, and how late.
class _FollowUpTile extends StatelessWidget {
  const _FollowUpTile(this.followUp);

  final FollowUp followUp;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final materialL10n = MaterialLocalizations.of(context);
    final overdue = followUp.isOverdue(DateTime.now());
    final due = followUp.dueAt;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      // Colour AND shape: an overdue return is the loudest thing on this
      // screen, and colour alone says nothing to a colour-blind reader.
      leading: Icon(
        overdue ? Icons.priority_high : Icons.hourglass_bottom,
        color: overdue ? context.zvColors.critical : context.zvColors.warning,
      ),
      title: Text(
        // The building first: it is what decides whether this fits today's
        // route. The nest is the second half of the same line.
        [
          ?followUp.spotName,
          if (followUp.nestLabel case final label?)
            l10n.dashboardFollowUpNest(label),
        ].join(' · '),
        style: theme.textTheme.titleSmall,
      ),
      subtitle: Text(
        due == null
            ? l10n.dueExplainFollowUpNoNest
            : overdue
            ? l10n.dashboardFollowUpOverdue(
                formatLocalDate(materialL10n, due),
              )
            : l10n.dashboardFollowUpDue(formatLocalDate(materialL10n, due)),
        style: theme.textTheme.bodySmall?.copyWith(
          color: overdue ? context.zvColors.critical : null,
          fontWeight: overdue ? FontWeight.bold : null,
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push(Routes.spotDetail(followUp.spot)),
    );
  }
}
