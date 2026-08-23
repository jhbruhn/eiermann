import 'dart:async';

import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/home/account_menu.dart';
import 'package:eiermann/features/tours/tour_sheet.dart';
import 'package:eiermann/features/tours/tours_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/routing/router.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// **Touren** — the route templates, and the way into a round.
///
/// Two things on one screen, in this order:
///
/// 1. **An open round, if there is one.** It sits at the top and it is not a
///    list item: a round somebody is in the middle of is the only thing on this
///    screen that is happening right now, and the app must not offer to start a
///    second one above it.
/// 2. **The templates**, each of which starts a round or opens its stop list.
///
/// Plus the improvised round at the bottom — no template, no name. That is not
/// a fallback for a missing template: tour scale in this group runs from one
/// building on the way home to a planned full-day sweep, and the small case is
/// the one an app most easily pushes out into a WhatsApp message.
class ToursScreen extends ConsumerWidget {
  const ToursScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final tours = ref.watch(allToursProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.toursTitle),
        actions: const [AccountMenu()],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showTourSheet(context),
        icon: const Icon(Icons.add),
        label: Text(l10n.tourNewAction),
      ),
      body: AsyncValueView(
        value: tours,
        onRetry: () => ref.invalidate(allToursProvider),
        data: (rows) => _ToursBody(rows: rows),
      ),
    );
  }
}

class _ToursBody extends ConsumerWidget {
  const _ToursBody({required this.rows});

  final List<Tour> rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final active = rows.where((tour) => tour.isActive).toList();
    final retired = rows.where((tour) => !tour.isActive).toList();

    return RefreshIndicator(
      onRefresh: () async {
        ref
          ..invalidate(allToursProvider)
          ..invalidate(myOpenRunProvider);
        await ref.read(allToursProvider.future);
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(ZugvogelSpacing.md),
        children: [
          const ContentBounds(child: OpenRunCard()),
          if (rows.isEmpty)
            ContentBounds(
              child: Padding(
                padding: const EdgeInsets.only(top: ZugvogelSpacing.xl),
                child: EmptyView(
                  icon: Icons.route_outlined,
                  title: l10n.toursEmptyTitle,
                  message: l10n.toursEmptyMessage,
                ),
              ),
            ),
          for (final tour in active)
            ContentBounds(child: _TourTile(tour: tour)),
          if (retired.isNotEmpty) ...[
            const SizedBox(height: ZugvogelSpacing.md),
            ContentBounds(
              child: Text(
                l10n.toursRetiredTitle,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            for (final tour in retired)
              ContentBounds(child: _TourTile(tour: tour)),
          ],
          const SizedBox(height: ZugvogelSpacing.lg),
          const ContentBounds(child: _AdHocCard()),
          // Room under the FAB, so the last row is reachable.
          const SizedBox(height: ZugvogelSpacing.xl * 2),
        ],
      ),
    );
  }
}

/// One template: its name, its stop count, and the two things to do with it.
class _TourTile extends ConsumerWidget {
  const _TourTile({required this.tour});

  final Tour tour;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final stops = ref.watch(tourStopsProvider(tour.id)).value;

    return Card(
      child: ListTile(
        leading: Icon(
          tour.isActive ? Icons.route : Icons.route_outlined,
          color: tour.isActive
              ? null
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        title: Text(tour.name),
        subtitle: Text(
          [
            // Null while the stop count is still loading, and it says so rather
            // than showing 0 — "Tour 1 · 0 Spots" would read as an empty route
            // and send somebody to edit one that is fine.
            if (stops == null)
              l10n.tourStopsLoading
            else
              l10n.tourStopCount(stops.length),
            ?tour.note,
          ].join(' · '),
        ),
        // The row opens the stop list; starting a round is the button, because
        // starting one is the irreversible-ish action of the two and must not
        // be what a mis-tap does.
        onTap: () => context.push(Routes.tourEditor(tour.id)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (tour.isActive)
              IconButton(
                icon: const Icon(Icons.play_arrow),
                tooltip: l10n.tourStartAction(tour.name),
                // A route with no stops can still be started: stops get added
                // while walking (that is what "Spot ergänzen" is for), and
                // refusing here would make the empty template a dead end
                // somebody has to fill in before they may leave the house.
                onPressed: () => startRun(context, ref, tour: tour),
              ),
            _TourMenu(tour: tour),
          ],
        ),
      ),
    );
  }
}

class _TourMenu extends ConsumerWidget {
  const _TourMenu({required this.tour});

  final Tour tour;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return PopupMenuButton<void>(
      itemBuilder: (_) => buildMenuItems([
        MenuAction(
          icon: Icons.edit_outlined,
          label: l10n.tourRenameAction,
          onTap: () => showTourSheet(context, tour: tour),
        ),
        // Retire, not delete. Deleting is the coordination's and it takes the
        // stop list with it while orphaning every round ever walked under the
        // route; retiring keeps both, and a retired route is still readable
        // next to its history.
        if (tour.isActive)
          MenuAction(
            icon: Icons.archive_outlined,
            label: l10n.tourRetireAction,
            onTap: () => _setActive(context, ref, active: false),
          )
        else
          MenuAction(
            icon: Icons.unarchive_outlined,
            label: l10n.tourReactivateAction,
            onTap: () => _setActive(context, ref, active: true),
          ),
      ]),
    );
  }

  Future<void> _setActive(
    BuildContext context,
    WidgetRef ref, {
    required bool active,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final strings = EiermannStrings(context.l10n);
    try {
      final repo = await ref.read(toursRepositoryProvider.future);
      if (active) {
        await repo.reactivate(tour.id);
      } else {
        await repo.retire(tour.id);
      }
      invalidateTourViews(ref);
    } on RepositoryException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(errorMessage(strings, e))));
    }
  }
}

/// The improvised round: no template, no name.
class _AdHocCard extends ConsumerWidget {
  const _AdHocCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(ZugvogelSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const IconChip(Icons.explore_outlined),
                const SizedBox(width: ZugvogelSpacing.md),
                Expanded(
                  child: Text(
                    l10n.tourAdHocTitle,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: ZugvogelSpacing.sm),
            Text(
              l10n.tourAdHocMessage,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: ZugvogelSpacing.md),
            PrimaryButton(
              label: l10n.tourAdHocStartAction,
              icon: Icons.play_arrow,
              onPressed: () => startRun(context, ref),
            ),
          ],
        ),
      ),
    );
  }
}

/// The open round, offered as "Tour 1 fortsetzen" — or nothing at all.
///
/// It reads the server, not the device. The open row IS the resume point, which
/// is what makes a round survive the app being killed, a phone rebooting, or
/// somebody switching to the tablet in the car: there is no local draft to be
/// missing on the other device, and no way for two devices to disagree about
/// how far the round got.
///
/// A failed read renders as nothing rather than as an error banner. This card
/// sits above everything, and a server hiccup must not push the templates off
/// the screen — the list below carries its own error state.
class OpenRunCard extends ConsumerWidget {
  const OpenRunCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final materialL10n = MaterialLocalizations.of(context);
    final run = ref.watch(myOpenRunProvider).value;
    if (run == null) return const SizedBox.shrink();

    final started = run.startedAt;
    return Card(
      color: theme.colorScheme.secondaryContainer,
      child: ListTile(
        leading: const Icon(Icons.directions_walk),
        title: Text(
          run.isAdHoc
              ? l10n.tourRunResumeAdHoc
              : l10n.tourRunResume(run.tourName),
          style: theme.textTheme.titleMedium,
        ),
        subtitle: started == null
            ? null
            : Text(
                l10n.tourRunStartedAt(
                  formatLocalDate(materialL10n, started),
                ),
              ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push(Routes.tourRun(run.id)),
      ),
    );
  }
}

/// Starts a round and goes to it.
///
/// **An open round wins over starting a new one.** If one is already open it
/// navigates there instead, and says so — two open rounds for one person is a
/// state nothing in the app wants: visits would land in whichever one the
/// screen happened to hold, and finishing one would leave the other being
/// offered forever. The server does not forbid it (a rule cannot count rows),
/// so this is where it is prevented.
Future<void> startRun(
  BuildContext context,
  WidgetRef ref, {
  Tour? tour,
}) async {
  final l10n = context.l10n;
  final strings = EiermannStrings(l10n);
  final messenger = ScaffoldMessenger.of(context);
  final router = GoRouter.of(context);

  try {
    final existing = await ref.read(myOpenRunProvider.future);
    if (existing != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.tourRunAlreadyOpen)),
      );
      unawaited(router.push(Routes.tourRun(existing.id)));
      return;
    }

    final user = await ref.read(currentUserProvider.future);
    final org = user?.org;
    if (org == null) throw const RepositoryException('no org for current user');

    final repo = await ref.read(tourRunsRepositoryProvider.future);
    // The template and the org, and nothing else. Who started it, when, and
    // under what name are the server's — a snapshot a client supplies is a
    // snapshot that can lie.
    final run = await repo.start(tour: tour?.id, org: org);
    invalidateRunViews(ref);
    unawaited(router.push(Routes.tourRun(run.id)));
  } on RepositoryException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(errorMessage(strings, e))));
  }
}
