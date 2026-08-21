import 'package:eiermann/features/spots/spot_labels.dart';
import 'package:eiermann/features/spots/spots_providers.dart';
import 'package:eiermann/features/tours/nearby_overdue.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/routing/router.dart';
import 'package:eiermann/ui/device_location.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// **Überfällig in meiner Nähe** — the improvised round's shortlist.
///
/// The ad-hoc mode in one block: a round with no template has no plan, so
/// instead of a route it offers the buildings that are late, nearest first.
/// Nothing is stored — there are no `tour_spots` rows for a round with no
/// template, and inventing them would put a route in the database that nobody
/// built and that gets walked once. Tapping an entry goes straight into the
/// visit flow carrying the round, and the visit is the whole record of it.
///
/// Location is asked for **on a tap, never on arrival**. A screen that fired a
/// permission prompt as it opened would ask before the reader has said they
/// want it, and the honest failure — refused, off, no fix in a stairwell —
/// leaves the list showing the fallback order rather than an error.
class NearbyOverdueBlock extends ConsumerStatefulWidget {
  const NearbyOverdueBlock({
    required this.runId,
    required this.exclude,
    super.key,
  });

  final String runId;

  /// Buildings already on this round. Suggesting one somebody has just visited
  /// is how a round gets walked twice.
  final Set<String> exclude;

  @override
  ConsumerState<NearbyOverdueBlock> createState() => _NearbyOverdueBlockState();
}

class _NearbyOverdueBlockState extends ConsumerState<NearbyOverdueBlock> {
  LocationFix? _me;
  bool _locating = false;

  Future<void> _locate() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _locating = true);
    try {
      final fix = await ref.read(deviceLocationProvider).current();
      if (!mounted) return;
      setState(() => _me = fix);
    } on LocationUnavailable catch (refusal) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(_message(l10n, refusal.reason))),
      );
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  /// Each refusal gets its own sentence, because the reader's next move
  /// differs: a service that is off gets switched on, a denied permission
  /// granted again, and a permanently denied one can only be changed in the
  /// system settings.
  ///
  /// Three of the four are the map's strings, unchanged — they say nothing
  /// about a map, and a second copy of "location is switched off on this
  /// device" would be two sentences to keep in step. Only the DENIED case is
  /// this screen's own: the map's version offers the search field instead, and
  /// what is on offer here is the same list in a different order.
  String _message(AppLocalizations l10n, LocationRefusal reason) =>
      switch (reason) {
        LocationRefusal.serviceOff => l10n.spotsMapLocationServiceOff,
        LocationRefusal.denied => l10n.tourNearbyLocationDenied,
        LocationRefusal.deniedForever => l10n.spotsMapLocationBlocked,
        LocationRefusal.unavailable => l10n.spotsMapLocationUnavailable,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final spots = ref.watch(allSpotsProvider).value ?? const [];
    final suggestions = overdueNearby(
      spots: spots,
      from: _me,
      exclude: widget.exclude,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(ZugvogelSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const IconChip(Icons.near_me_outlined),
                const SizedBox(width: ZugvogelSpacing.md),
                Expanded(
                  child: Text(
                    l10n.tourNearbyTitle,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (_locating)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.my_location),
                    tooltip: l10n.tourNearbyLocateAction,
                    onPressed: _locate,
                  ),
              ],
            ),
            const SizedBox(height: ZugvogelSpacing.sm),
            Text(
              // Which order this list is in, said out loud. Without it a list
              // sorted by urgency looks like a list sorted by distance that is
              // simply wrong.
              _me == null ? l10n.tourNearbyNoFix : l10n.tourNearbyByDistance,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: ZugvogelSpacing.sm),
            if (suggestions.isEmpty)
              Text(l10n.tourNearbyEmpty, style: theme.textTheme.bodySmall)
            else
              for (final entry in suggestions)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(
                    spotUrgencyIcon(entry.spot.level),
                    color: spotUrgencyColor(context, entry.spot.level),
                  ),
                  title: Text(entry.spot.name),
                  subtitle: Text(
                    [
                      if (entry.metres case final m?) _distance(l10n, m),
                      ?entry.spot.addressLine,
                    ].join(' · '),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push(
                    Routes.spotVisit(entry.spot.id, run: widget.runId),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  /// Metres under a kilometre, kilometres above it. A "1400 m" nobody converts
  /// in their head is a number that does not help somebody decide whether to
  /// walk.
  String _distance(AppLocalizations l10n, double metres) => metres < 1000
      ? l10n.tourNearbyMetres(metres.round())
      : l10n.tourNearbyKilometres((metres / 100).round() / 10);
}
