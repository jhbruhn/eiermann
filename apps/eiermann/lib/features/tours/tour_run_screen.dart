import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/spots/spot_labels.dart';
import 'package:eiermann/features/spots/spots_providers.dart';
import 'package:eiermann/features/tours/nearby_overdue_block.dart';
import 'package:eiermann/features/tours/tour_spot_picker.dart';
import 'package:eiermann/features/tours/tours_providers.dart';
import 'package:eiermann/features/visits/check_labels.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/routing/router.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// A round in progress: the route as an ordered list, what has been settled,
/// and the three things somebody does while walking it.
///
/// **Adding and skipping are equal-rank actions, not error paths.** They are
/// the same row shape in the database and the same weight here: "Spot
/// ergänzen" is a button, not an item in an overflow menu, and a skipped stop
/// is a completed line with a reason rather than a red failure. The route
/// somebody planned last month and the round they are actually walking today
/// are allowed to differ; an app that treats every deviation as a mistake gets
/// closed, and the round gets written in WhatsApp again.
///
/// **Nothing here is held on the device.** The progress is the visits, read
/// from the server (see `tourProgress`), and the round's open state is a
/// missing `finished_at`. So the screen can be reached fresh on another device,
/// after a reboot, or an hour later, and it shows exactly the same thing — the
/// one part of a round that a local draft could never give.
class TourRunScreen extends ConsumerWidget {
  const TourRunScreen({required this.runId, super.key});

  final String runId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final run = ref.watch(tourRunProvider(runId));
    final progress = ref.watch(tourRunProgressProvider(runId));

    return Scaffold(
      appBar: AppBar(
        title: Text(
          switch (run.value) {
            null => l10n.tourRunTitle,
            final r when r.isAdHoc => l10n.tourRunTitleAdHoc,
            final r => r.tourName,
          },
        ),
        actions: [
          if (run.value case final r? when r.isOpen)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: l10n.tourRunDiscardAction,
              onPressed: () => _discard(context, ref, r),
            ),
        ],
      ),
      body: AsyncValueView(
        value: progress,
        onRetry: () => ref.invalidate(tourRunProgressProvider(runId)),
        data: (value) => _RunBody(
          runId: runId,
          run: run.value,
          progress: value,
        ),
      ),
    );
  }

  /// Throws the round away.
  ///
  /// Only reachable while it is open — the server refuses a finished one, and
  /// rightly: a finished round is what a set of visits was walked as. This is
  /// for the wrong tap on the dashboard, which would otherwise be offered as
  /// "fortsetzen" forever.
  ///
  /// The dialog names what SURVIVES, because that is the part people get
  /// wrong: visits already recorded do not go away. They stand, without a
  /// round.
  Future<void> _discard(
    BuildContext context,
    WidgetRef ref,
    TourRun run,
  ) async {
    final l10n = context.l10n;
    final strings = EiermannStrings(l10n);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final visits = await ref.read(tourRunVisitsProvider(runId).future);

    if (!context.mounted) return;
    final choice = await showDialog<DestructiveChoice>(
      context: context,
      builder: (_) => DestructiveDialog(
        title: l10n.tourRunDiscardTitle,
        intro: l10n.tourRunDiscardIntro,
        bullets: [
          // Not a warning line: what it says is that the visits SURVIVE, and
          // rendering the reassuring half in the error colour would read as the
          // opposite of what it means.
          if (visits.isEmpty)
            (l10n.tourRunDiscardNothingRecorded, false)
          else
            (l10n.tourRunDiscardVisitsStay(visits.length), false),
        ],
        confirmLabel: l10n.tourRunDiscardAction,
        confirmIcon: Icons.delete_outline,
      ),
    );
    if (choice != DestructiveChoice.confirm) return;

    try {
      final repo = await ref.read(tourRunsRepositoryProvider.future);
      await repo.discard(run.id);
      invalidateRunViews(ref);
      router.go(Routes.tours);
    } on RepositoryException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(errorMessage(strings, e))));
    }
  }
}

class _RunBody extends ConsumerWidget {
  const _RunBody({
    required this.runId,
    required this.progress,
    this.run,
  });

  final String runId;
  final TourRun? run;
  final TourProgress progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final spots = ref.watch(allSpotsProvider).value ?? const [];
    final byId = {for (final spot in spots) spot.id: spot};
    final open = run?.isOpen ?? false;

    return RefreshIndicator(
      onRefresh: () async {
        invalidateRunViews(ref);
        await ref.read(tourRunProgressProvider(runId).future);
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(ZugvogelSpacing.md),
        children: [
          ContentBounds(
            child: _ProgressHeader(progress: progress, run: run),
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          if (progress.entries.isEmpty)
            ContentBounds(
              child: EmptyView(
                icon: Icons.add_location_alt_outlined,
                title: l10n.tourRunEmptyTitle,
                // An ad-hoc round starts empty BY DESIGN, so this is not an
                // error state — it is the instruction for what to do next.
                message: l10n.tourRunEmptyMessage,
              ),
            ),
          for (final entry in progress.entries)
            ContentBounds(
              child: _StopRow(
                runId: runId,
                entry: entry,
                overview: byId[entry.spot],
                runIsOpen: open,
              ),
            ),
          const SizedBox(height: ZugvogelSpacing.lg),
          // The improvised round's shortlist. Only for a round with no plan:
          // on a real Tour the plan IS the list, and a second one underneath it
          // would compete with the route somebody is walking.
          if (open && progress.plannedCount == 0)
            ContentBounds(
              child: NearbyOverdueBlock(
                runId: runId,
                exclude: progress.entries.map((e) => e.spot).toSet(),
              ),
            ),
          if (open) const SizedBox(height: ZugvogelSpacing.lg),
          if (open)
            ContentBounds(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Equal rank with the stops above, deliberately: a building
                  // somebody passes on the way is part of the round, and
                  // burying this in a menu is what makes people record it
                  // nowhere.
                  OutlinedButton.icon(
                    onPressed: () => _addSpot(context, ref),
                    icon: const Icon(Icons.add_location_alt_outlined),
                    label: Text(l10n.tourRunAddSpotAction),
                  ),
                  const SizedBox(height: ZugvogelSpacing.md),
                  PrimaryButton(
                    label: l10n.tourRunFinishAction,
                    icon: Icons.flag_outlined,
                    onPressed: () => _finish(context, ref),
                  ),
                  if (!progress.isComplete) ...[
                    const SizedBox(height: ZugvogelSpacing.sm),
                    Text(
                      // Finishing with stops left is allowed and says so. A
                      // disabled button would mean the only way out of a round
                      // that cannot be completed today is to discard it — and
                      // the visits already made deserve better than that.
                      l10n.tourRunFinishEarlyHint(
                        progress.plannedCount - progress.plannedDone,
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            )
          else
            ContentBounds(
              child: Text(
                l10n.tourRunFinished,
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _addSpot(BuildContext context, WidgetRef ref) async {
    final spot = await showTourSpotPicker(
      context,
      // Everything already on this round, planned or added. A building visited
      // twice in one round is legitimate in the data (the latest visit wins)
      // but it is never what somebody means by "ergänzen" — the stop is already
      // in the list, and tapping it is the way back to it.
      exclude: progress.entries.map((entry) => entry.spot).toSet(),
      title: context.l10n.tourRunAddSpotAction,
    );
    if (spot == null || !context.mounted) return;
    // Straight into the visit flow, carrying the round. Nothing is written for
    // the addition itself — the visit IS the addition, which is why there is no
    // half-added stop to clean up if somebody backs out here.
    await context.push(Routes.spotVisit(spot.id, run: runId));
  }

  Future<void> _finish(BuildContext context, WidgetRef ref) async {
    final strings = EiermannStrings(context.l10n);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final repo = await ref.read(tourRunsRepositoryProvider.future);
      await repo.finish(runId);
      invalidateRunViews(ref);
      if (navigator.canPop()) navigator.pop();
    } on RepositoryException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(errorMessage(strings, e))));
    }
  }
}

/// How far the round has got, as one line and one bar.
class _ProgressHeader extends StatelessWidget {
  const _ProgressHeader({required this.progress, this.run});

  final TourProgress progress;
  final TourRun? run;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final planned = progress.plannedCount;
    final done = progress.plannedDone;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(ZugvogelSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              // Two shapes, because "3 von 7" is meaningless on a round with no
              // plan — every stop there is an addition, and the count of them
              // is the whole story.
              planned == 0
                  ? l10n.tourRunProgressAdHoc(progress.addedCount)
                  : l10n.tourRunProgress(done, planned),
              style: theme.textTheme.titleMedium,
            ),
            if (planned > 0) ...[
              const SizedBox(height: ZugvogelSpacing.sm),
              LinearProgressIndicator(
                value: done / planned,
                // The bar is never the only signal — the line above says the
                // same thing in words, for a reader who cannot see it.
                semanticsLabel: l10n.tourRunProgress(done, planned),
              ),
            ],
            if (planned > 0 && progress.addedCount > 0) ...[
              const SizedBox(height: ZugvogelSpacing.sm),
              Text(
                l10n.tourRunAdded(progress.addedCount),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (run?.startedByName case final who? when who.isNotEmpty) ...[
              const SizedBox(height: ZugvogelSpacing.sm),
              Text(
                l10n.tourRunWalkedBy(who),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One stop: where it stands, and the two ways to settle it.
class _StopRow extends StatelessWidget {
  const _StopRow({
    required this.runId,
    required this.entry,
    required this.runIsOpen,
    this.overview,
  });

  final String runId;
  final TourStopProgress entry;
  final SpotOverview? overview;
  final bool runIsOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final name = entry.spotName ?? overview?.name ?? l10n.tourStopUnknownSpot;

    return Card(
      child: ListTile(
        leading: _StateIcon(entry: entry, overview: overview),
        title: Text(
          name,
          style: entry.isDone
              ? theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                )
              : theme.textTheme.titleMedium,
        ),
        subtitle: Text(_subtitle(l10n)),
        trailing: entry.isDone || !runIsOpen
            // A settled stop leads to the dossier — "what did we find here" is
            // the question then, not "check it again".
            ? const Icon(Icons.chevron_right)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Skip and check, side by side and the same size. The concept
                  // asks for this in as many words: both are outcomes, and
                  // "nobody there" is a fact about the building.
                  IconButton(
                    icon: const Icon(Icons.block_outlined),
                    tooltip: l10n.tourRunSkipAction,
                    onPressed: () => context.push(
                      Routes.spotVisit(entry.spot, skipped: true, run: runId),
                    ),
                  ),
                  IconButton.filled(
                    icon: const Icon(Icons.checklist),
                    tooltip: l10n.tourRunCheckAction,
                    onPressed: () => context.push(
                      Routes.spotVisit(entry.spot, run: runId),
                    ),
                  ),
                ],
              ),
        onTap: entry.isDone || !runIsOpen
            ? () => context.push(Routes.spotDetail(entry.spot))
            : () => context.push(Routes.spotVisit(entry.spot, run: runId)),
      ),
    );
  }

  String _subtitle(AppLocalizations l10n) {
    final parts = <String>[
      if (!entry.planned) l10n.tourRunAddedStop,
      switch (entry.state) {
        TourStopState.pending => overview?.addressLine ?? '',
        TourStopState.checked => l10n.tourRunStopChecked,
        // The reason, because a skip without one says nothing about whether
        // anybody tried. An unknown reason falls back to the plain word rather
        // than to a guess.
        TourStopState.skipped => l10n.tourRunStopSkipped(
          skipReasonLabel(l10n, entry.skipReason),
        ),
      },
    ];
    return parts.where((part) => part.isNotEmpty).join(' · ');
  }
}

/// The leading icon: state first, urgency only while a stop is still pending.
///
/// Once a stop is settled its urgency is the wrong thing to show — the rank on
/// the row would still say "overdue" until the server recomputes, and a reader
/// halfway down a round would see a building they just checked shouting for
/// attention.
class _StateIcon extends StatelessWidget {
  const _StateIcon({required this.entry, this.overview});

  final TourStopProgress entry;
  final SpotOverview? overview;

  @override
  Widget build(BuildContext context) {
    return switch (entry.state) {
      TourStopState.checked => Icon(
        Icons.check_circle,
        color: context.zvColors.good,
      ),
      // Shape AND colour: a skip is a completed line, not a failure, so it gets
      // its own glyph rather than a red version of the checkmark.
      TourStopState.skipped => Icon(
        Icons.block,
        color: context.zvColors.warning,
      ),
      TourStopState.pending => Icon(
        spotUrgencyIcon(overview?.level),
        color: spotUrgencyColor(context, overview?.level),
      ),
    };
  }
}
