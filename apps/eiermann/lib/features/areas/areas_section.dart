import 'dart:async';

import 'package:eiermann/features/areas/area_photo.dart';
import 'package:eiermann/features/areas/area_sheet.dart';
import 'package:eiermann/features/areas/areas_providers.dart';
import 'package:eiermann/features/nests/nest_list.dart';
import 'package:eiermann/features/nests/nests_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/routing/router.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// The Bereiche of one Spot, each with its overview photo.
///
/// This is the block the concept puts directly under the header: you look at a
/// picture of the attic and orient yourself physically, before reading a single
/// word. The nest pins land on these photos in eiermann-bmg.4 and the nest
/// lines under them in bmg.6 — which is why the photo, not the name, is the
/// biggest thing in a card.
class AreasSection extends ConsumerWidget {
  const AreasSection({required this.spotId, super.key});

  final String spotId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final areas = ref.watch(areasForSpotProvider(spotId));
    // ONE read of the nests for the whole dossier, sliced per Bereich below. A
    // card that fetched its own would be a request per Bereich — the view
    // exists so this screen stays two queries however big the building is.
    final nests = ref.watch(nestStatesForSpotProvider(spotId));

    return AreaSectionShell(
      title: l10n.areasTitle,
      action: TextButton.icon(
        onPressed: () => showAreaSheet(context, spotId: spotId),
        icon: const Icon(Icons.add),
        label: Text(l10n.areasAddAction),
      ),
      child: AsyncValueView(
        value: areas,
        onRetry: () => ref.invalidate(areasForSpotProvider(spotId)),
        data: (rows) => rows.isEmpty
            ? Text(l10n.areasEmpty)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final area in rows)
                    Padding(
                      padding: const EdgeInsets.only(
                        bottom: ZugvogelSpacing.md,
                      ),
                      child: AreaCard(
                        area: area,
                        spotId: spotId,
                        // Null while the nests are still being read, which is
                        // not the same as "no nests": the card then says
                        // nothing rather than calling the Bereich empty.
                        nests: nests.value
                            ?.where((nest) => nest.area == area.id)
                            .toList(),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

/// An icon-less section header with an action, matching the dossier's blocks.
///
/// Public only because the dossier composes it; the sections there are private
/// to that file and this one has to look identical beside them.
class AreaSectionShell extends StatelessWidget {
  const AreaSectionShell({
    required this.title,
    required this.child,
    this.action,
    super.key,
  });

  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const IconChip(Icons.meeting_room_outlined),
            const SizedBox(width: ZugvogelSpacing.md),
            Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
            ?action,
          ],
        ),
        const SizedBox(height: ZugvogelSpacing.sm),
        child,
      ],
    );
  }
}

/// One Bereich: its photo, its name, and what somebody wrote about getting in.
class AreaCard extends ConsumerWidget {
  const AreaCard({
    required this.area,
    required this.spotId,
    this.nests,
    super.key,
  });

  final Area area;
  final String spotId;

  /// The nests of THIS Bereich, or null while they are still being read.
  final List<NestState>? nests;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final materialL10n = MaterialLocalizations.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Tapping the photo goes to the pin editor, not to a viewer: the
          // pins ARE what this picture is for, and the viewer is one tap
          // further in from there.
          AreaPhoto(
            area: area,
            onTap: () => context.push(Routes.areaEditor(area.id)),
          ),
          Padding(
            padding: const EdgeInsets.all(ZugvogelSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        area.name,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    // Two actions, and the photo one is not hidden in a menu:
                    // taking the photo IS the work on a fresh Bereich, and on a
                    // phone in a stairwell it has to be one tap.
                    IconButton(
                      icon: Icon(
                        area.hasPhoto
                            ? Icons.photo_camera_outlined
                            : Icons.add_a_photo_outlined,
                      ),
                      tooltip: area.hasPhoto
                          ? l10n.areaPhotoReplaceAction
                          : l10n.areaPhotoSetAction,
                      onPressed: () => unawaited(
                        changeAreaPhoto(context, ref, area: area),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: l10n.areaEditAction,
                      onPressed: () =>
                          showAreaSheet(context, spotId: spotId, area: area),
                    ),
                  ],
                ),
                if (area.note case final note?)
                  Text(note, style: theme.textTheme.bodyMedium),
                // The flag the replacement hook raises (eiermann-bmg.5). Read
                // and stated even before the review pass exists: an area whose
                // pins nobody has checked against the new photo is the one
                // state where the picture actively misleads, and going quiet
                // about it would be worse than having no photo at all.
                if (area.pinsNeedReview) ...[
                  const SizedBox(height: ZugvogelSpacing.sm),
                  Row(
                    children: [
                      Icon(
                        Icons.warning_amber_outlined,
                        size: 18,
                        color: context.zvColors.warning,
                      ),
                      const SizedBox(width: ZugvogelSpacing.xs),
                      Expanded(
                        child: Text(
                          l10n.areaPinsNeedReview,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: context.zvColors.warning,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (nests case final rows?) ...[
                  const SizedBox(height: ZugvogelSpacing.sm),
                  const Divider(height: 1),
                  NestList(nests: rows, areaId: area.id),
                ],
                if (area.photoTakenAt case final taken?) ...[
                  const SizedBox(height: ZugvogelSpacing.xs),
                  Text(
                    // How old the picture is decides whether it can be trusted:
                    // a photo from two years ago has had a whole nest built and
                    // netted over since.
                    l10n.areaPhotoTakenOn(
                      formatLocalDate(materialL10n, taken),
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
