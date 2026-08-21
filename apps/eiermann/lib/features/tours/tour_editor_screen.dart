import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/spots/spot_labels.dart';
import 'package:eiermann/features/spots/spots_providers.dart';
import 'package:eiermann/features/tours/tour_sheet.dart';
import 'package:eiermann/features/tours/tour_spot_picker.dart';
import 'package:eiermann/features/tours/tours_providers.dart';
import 'package:eiermann/features/tours/tours_screen.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/routing/router.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// One template's ordered stop list.
///
/// The order IS the route — ground floor before the attic, this street before
/// that one — and it is what makes the handover survivable, so it is editable
/// by dragging rather than by a number field. A `sort_index` somebody types is
/// a number they have to compute; a drag is the thing they mean.
///
/// **A stop cannot be re-pointed.** There is no "change building" on a row,
/// because the server refuses it and would be right to: re-pointing silently
/// rewrites what a route IS while every screen keeps showing the same row.
/// Removing and adding is one extra tap and says what happened.
class TourEditorScreen extends ConsumerWidget {
  const TourEditorScreen({required this.tourId, super.key});

  final String tourId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final tours = ref.watch(allToursProvider);
    final stops = ref.watch(tourStopsProvider(tourId));
    final tour = tours.value?.where((t) => t.id == tourId).firstOrNull;

    return Scaffold(
      appBar: AppBar(
        title: Text(tour?.name ?? l10n.toursTitle),
        actions: [
          if (tour != null)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: l10n.tourRenameAction,
              onPressed: () => showTourSheet(context, tour: tour),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addStop(context, ref, stops.value ?? const []),
        icon: const Icon(Icons.add_location_alt_outlined),
        label: Text(l10n.tourStopAddAction),
      ),
      body: AsyncValueView(
        value: stops,
        onRetry: () => ref.invalidate(tourStopsProvider(tourId)),
        data: (rows) => _StopList(
          tourId: tourId,
          tour: tour,
          stops: rows,
        ),
      ),
    );
  }

  Future<void> _addStop(
    BuildContext context,
    WidgetRef ref,
    List<TourStop> stops,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final strings = EiermannStrings(context.l10n);
    final spot = await showTourSpotPicker(
      context,
      // The buildings already on the route. The collection has a unique index
      // on (tour, spot) so a duplicate would be refused anyway — excluding them
      // here means nobody gets to press a row that then fails.
      exclude: stops.map((stop) => stop.spot).toSet(),
    );
    if (spot == null) return;

    try {
      final user = await ref.read(currentUserProvider.future);
      final org = user?.org;
      if (org == null) {
        throw const RepositoryException('no org for current user');
      }
      final repo = await ref.read(tourStopsRepositoryProvider.future);
      await repo.create(
        TourStopsRepository.body(
          tour: tourId,
          spot: spot.id,
          // Appended, not inserted. Somebody adding a building to a route is
          // saying "and this one too"; guessing where it belongs in the order
          // would move a route they did not ask to have reordered.
          sortIndex: stops.length,
          org: org,
        ),
      );
      invalidateTourViews(ref);
    } on RepositoryException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(errorMessage(strings, e))));
    }
  }
}

class _StopList extends ConsumerWidget {
  const _StopList({required this.tourId, required this.stops, this.tour});

  final String tourId;
  final Tour? tour;
  final List<TourStop> stops;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final spots = ref.watch(allSpotsProvider).value ?? const [];
    final byId = {for (final spot in spots) spot.id: spot};

    if (stops.isEmpty) {
      return EmptyView(
        icon: Icons.add_location_alt_outlined,
        title: l10n.tourStopsEmptyTitle,
        message: l10n.tourStopsEmptyMessage,
      );
    }

    return Column(
      children: [
        if (tour case final t? when t.isActive)
          Padding(
            padding: const EdgeInsets.all(ZugvogelSpacing.md),
            child: ContentBounds(
              child: PrimaryButton(
                label: l10n.tourStartAction(t.name),
                icon: Icons.play_arrow,
                onPressed: () => startRun(context, ref, tour: t),
              ),
            ),
          ),
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.only(bottom: ZugvogelSpacing.xl * 2),
            itemCount: stops.length,
            // `onReorderItem`, not `onReorder`: the deprecated one reports the
            // target index in the list as it was BEFORE the row was lifted, so
            // every downward move is off by one and the caller has to correct
            // for it. This one has already done that.
            onReorderItem: (from, to) => _reorder(context, ref, from, to),
            itemBuilder: (_, index) {
              final stop = stops[index];
              // The expand's name first, then the loaded overview row, and
              // never the id: an id with no label next to it is a bug in this
              // app.
              final overview = byId[stop.spot];
              final name = stop.spotName ?? overview?.name;
              return ListTile(
                key: ValueKey(stop.id),
                leading: CircleAvatar(child: Text('${index + 1}')),
                title: Text(name ?? l10n.tourStopUnknownSpot),
                subtitle: overview?.addressLine == null
                    ? null
                    : Text(overview!.addressLine!),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (overview?.level case final level?)
                      Icon(
                        spotUrgencyIcon(level),
                        color: spotUrgencyColor(context, level),
                      ),
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      tooltip: l10n.tourStopRemoveAction,
                      onPressed: () => _remove(context, ref, stop),
                    ),
                    // The drag handle stays last so it is where a thumb
                    // expects it; the row itself opens the dossier, because
                    // "what IS this building" is the question somebody has
                    // while building a route.
                    ReorderableDragStartListener(
                      index: index,
                      child: const Icon(Icons.drag_handle),
                    ),
                  ],
                ),
                onTap: () => context.push(Routes.spotDetail(stop.spot)),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _reorder(
    BuildContext context,
    WidgetRef ref,
    int from,
    int to,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final strings = EiermannStrings(context.l10n);
    final next = [...stops];
    next.insert(to, next.removeAt(from));

    try {
      final repo = await ref.read(tourStopsRepositoryProvider.future);
      // One write per stop whose index actually changed — a drag moves a
      // handful of neighbours, not the whole route.
      await repo.reorder(next);
      invalidateTourViews(ref);
    } on RepositoryException catch (e) {
      // No optimistic local order to unwind: the list is rebuilt from the
      // server, so a failed reorder simply shows the order that is still
      // stored. Which is the honest thing to show.
      invalidateTourViews(ref);
      messenger.showSnackBar(SnackBar(content: Text(errorMessage(strings, e))));
    }
  }

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    TourStop stop,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final strings = EiermannStrings(context.l10n);
    try {
      final repo = await ref.read(tourStopsRepositoryProvider.future);
      await repo.delete(stop.id);
      // No confirmation dialog: nothing hangs off a stop — no visit, no nest,
      // no history — so this destroys one row that is one tap to put back. A
      // dialog here would train people to dismiss the ones that matter.
      invalidateTourViews(ref);
    } on RepositoryException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(errorMessage(strings, e))));
    }
  }
}
