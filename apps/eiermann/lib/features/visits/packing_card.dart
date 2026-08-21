import 'package:eiermann/features/visits/packing.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// "Einpacken: 3 Attrappen" — the concept's smallest feature with the highest
/// everyday value.
///
/// ONE widget for the two places that show it, the dossier and the visit flow,
/// because two copies of a derived number is how they come to disagree — and
/// this is the number somebody loads the car by. See [dummiesToPack] for the
/// derivation and its limits.
class PackingCard extends StatelessWidget {
  const PackingCard({required this.nests, super.key});

  final List<NestState> nests;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final count = dummiesToPack(nests);

    return Card(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(ZugvogelSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.backpack_outlined,
              color: theme.colorScheme.onSecondaryContainer,
            ),
            const SizedBox(width: ZugvogelSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    // Zero is a real answer and gets said out loud: a missing
                    // line reads as "not computed yet".
                    count == 0
                        ? l10n.spotPackNone
                        : l10n.spotPackDummies(count),
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                  const SizedBox(height: ZugvogelSpacing.xs),
                  Text(
                    l10n.spotPackHint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
