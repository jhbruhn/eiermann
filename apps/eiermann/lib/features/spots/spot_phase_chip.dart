import 'package:eiermann/features/spots/spot_labels.dart';
import 'package:eiermann/features/spots/spot_phase_sheet.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// The Spot's phase, and the way to change it — one control, because they are
/// one thing.
///
/// It offers exactly the moves `app_spot_phase.js` accepts (see
/// [SpotPhaseMoves.allowedPhases]), plus "Pause bearbeiten" for a Spot already
/// paused, which is not a transition. A control that offered the full set of
/// phases would offer three refusals out of four from `closed` — and the user
/// would read a German sentence explaining a mistake the app had invited.
///
/// Closing is NOT marked destructive, though it is the heaviest move here.
/// Destructive means irreversible, and closing is the opposite: it is the
/// reversible route that keeps the whole dossier, offered so nobody reaches for
/// delete. Painting it in the error colour would make the safe route look like
/// the dangerous one.
class SpotPhaseChip extends StatelessWidget {
  const SpotPhaseChip(this.spot, {super.key});

  final Spot spot;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final moves = [
      ...spot.allowedPhases,
      // Last: correcting a pause is housekeeping, and the moves OUT of the
      // pause are what somebody opened the menu for.
      if (spot.phase == SpotPhase.paused) SpotPhase.paused,
    ];

    if (moves.isEmpty) {
      // A phase this build cannot name. Saying so beats a menu of guesses, and
      // beats a chip that looks tappable and does nothing.
      return Tooltip(
        message: l10n.spotPhaseNoMoves,
        child: _Face(spot: spot, actionable: false),
      );
    }

    return PopupMenuButton<void>(
      tooltip: l10n.spotPhaseChangeAction,
      itemBuilder: (_) => buildMenuItems([
        for (final target in moves)
          MenuAction(
            icon: spotPhaseIcon(target),
            label: spotPhaseMoveLabel(l10n, spot.phase!, target),
            onTap: () =>
                showSpotPhaseSheet(context, spot: spot, target: target),
          ),
      ]),
      child: _Face(spot: spot, actionable: true),
    );
  }
}

/// The chip itself: icon, word, and — when there is a menu behind it — the
/// arrow that says so.
class _Face extends StatelessWidget {
  const _Face({required this.spot, required this.actionable});

  final Spot spot;
  final bool actionable;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    // Only `closed` is coloured, and it is the one phase that means "do not go
    // here". Paused and prospect are not degrees of the same thing — colouring
    // them would invite the reader to rank all four, and the icon plus the word
    // already tell them apart. Same restraint as the urgency ranks in the list.
    final alert = spot.phase == SpotPhase.closed;

    return Chip(
      avatar: Icon(
        spotPhaseIcon(spot.phase),
        size: 18,
        color: alert ? theme.colorScheme.onErrorContainer : null,
      ),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(spotPhaseLabel(l10n, spot.phase)),
          if (actionable) const Icon(Icons.arrow_drop_down, size: 18),
        ],
      ),
      visualDensity: VisualDensity.compact,
      backgroundColor: alert ? theme.colorScheme.errorContainer : null,
      labelStyle: alert
          ? TextStyle(color: theme.colorScheme.onErrorContainer)
          : null,
    );
  }
}
