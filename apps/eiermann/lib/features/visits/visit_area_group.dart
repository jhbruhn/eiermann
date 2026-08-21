import 'dart:async';

import 'package:eiermann/features/areas/area_photo.dart';
import 'package:eiermann/features/areas/pin_canvas.dart';
import 'package:eiermann/features/nests/nest_labels.dart';
import 'package:eiermann/features/nests/nest_list.dart';
import 'package:eiermann/features/visits/check_labels.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/routing/router.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// One Bereich inside the Besuchsablauf: its overview photo, and the nests of
/// that Bereich as lines under it.
///
/// **The photo belongs here more than anywhere else.** The dossier shows it so
/// somebody at a desk can see what they are sending a volunteer into; this is
/// the screen that person is holding while standing in the attic. Without the
/// picture the flow is a list of labels — "N3", "Balken links" — and matching
/// those to what is in front of you is exactly the work the photo was taken to
/// remove. It is worst on a Tour, where five buildings' worth of labels arrive
/// in one afternoon and none of them mean anything on their own.
///
/// **The pins say what has been recorded so far.** A nest already dealt with
/// carries its check state on the photo, in the same icon and colour as its
/// line — a pin that kept announcing "Stadttaube" beside a line reading
/// "getauscht" would be one nest saying two things on one screen. So the photo
/// is the working surface: tap the nest where it sits, and the visit's progress
/// is visible without reading a single label.
class VisitAreaGroup extends ConsumerWidget {
  const VisitAreaGroup({
    required this.nests,
    required this.drafts,
    required this.onOpenNest,
    required this.enabled,
    this.area,
    super.key,
  });

  /// The Bereich these nests sit in, or null when it could not be read.
  ///
  /// Null is not an error state to display: the nests are the work, and a nest
  /// must not drop out of a visit because a photo listing failed. It renders as
  /// bare lines — the flow as it was before there was a photo on it.
  final Area? area;

  /// The nests of this Bereich, in the server's order — urgent first.
  final List<NestState> nests;

  /// What this visit has recorded so far, by nest id. The whole map rather
  /// than this Bereich's slice, because it is what the caller holds and
  /// slicing it here would be a second grouping to keep in step.
  final Map<String, NestCheckDraft> drafts;

  final void Function(NestState nest) onOpenNest;

  /// False while the visit is being sent: the screen takes no more work then.
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bereich = area;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (bereich != null) ...[
          _Header(area: bereich, enabled: enabled),
          if (bereich.hasPhoto) ...[
            const SizedBox(height: ZugvogelSpacing.sm),
            _Photo(
              area: bereich,
              nests: nests,
              drafts: drafts,
              onOpenNest: onOpenNest,
              enabled: enabled,
            ),
          ],
          if (bereich.pinsNeedReview) _PinsNeedReview(area: bereich),
        ],
        for (final nest in nests)
          VisitNestRow(
            nest: nest,
            draft: drafts[nest.id],
            onTap: enabled ? () => onOpenNest(nest) : null,
          ),
      ],
    );
  }
}

/// The Bereich's name, and the one control that changes its photo.
///
/// The control is in the header rather than on the picture, and there is
/// exactly one of it, because the two cases are one action with two labels: a
/// Bereich with a photo offers to replace it, one without offers to take it —
/// and the second is the one that needs a visible word rather than an icon,
/// since a flow with no picture on it is where somebody has to notice that
/// taking one is even possible.
///
/// **Taking it here writes at once**, unlike everything else on this screen.
/// That is right rather than a leak in the "everything in memory until the last
/// button" rule: the photo belongs to the building, not to the visit, and a
/// picture taken in an attic that was lost because the send failed an hour
/// later would have to be taken again by somebody driving back.
class _Header extends ConsumerWidget {
  const _Header({required this.area, required this.enabled});

  final Area area;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    void change() => unawaited(changeAreaPhoto(context, ref, area: area));

    return Row(
      children: [
        Icon(
          Icons.meeting_room_outlined,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: ZugvogelSpacing.sm),
        Expanded(child: Text(area.name, style: theme.textTheme.titleSmall)),
        if (area.hasPhoto)
          IconButton(
            icon: const Icon(Icons.photo_camera_outlined),
            tooltip: l10n.areaPhotoReplaceAction,
            onPressed: enabled ? change : null,
          )
        else
          TextButton.icon(
            onPressed: enabled ? change : null,
            icon: const Icon(Icons.add_a_photo_outlined),
            label: Text(l10n.areaPhotoSetAction),
          ),
      ],
    );
  }
}

/// The overview photo with the nests marked on it, as the visit's working
/// surface.
///
/// **One gesture on it: a pin opens that nest's check sheet.** The picture
/// itself does nothing, deliberately — everything the photo is for here is
/// answered by looking at it, and a second gesture on the same few hundred
/// pixels would mostly be triggered by fingers aiming at a pin.
class _Photo extends ConsumerWidget {
  const _Photo({
    required this.area,
    required this.nests,
    required this.drafts,
    required this.onOpenNest,
    required this.enabled,
  });

  final Area area;
  final List<NestState> nests;
  final Map<String, NestCheckDraft> drafts;
  final void Function(NestState nest) onOpenNest;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final byId = {for (final nest in nests) nest.id: nest};

    return PinCanvas(
      // Canvas mode, so the box IS the image: inside the 16:10 letterbox the
      // dossier's card uses, every pin would sit slightly off its nest.
      photo: AreaPhoto(area: area, showAsCanvas: true),
      nests: PinnedNest.fromStates(
        nests,
        mark: (nest) => _mark(context, l10n, nest),
      ),
      // Full-size pins, not the dossier's dense preview: on a phone these are
      // the touch targets, and the dense ones are 10pt text.
      onOpen: enabled
          ? (pin) {
              final nest = byId[pin.id];
              if (nest != null) onOpenNest(nest);
            }
          : null,
    );
  }

  /// The check state of a nest this visit has already recorded — or null, which
  /// leaves the species pin standing.
  ///
  /// The same three labels the line under the photo uses ([checkStateIcon],
  /// [checkStateColor], [checkStateLabel]), because they are the same fact.
  PinMark? _mark(BuildContext context, AppLocalizations l10n, NestState nest) {
    final draft = drafts[nest.id];
    if (draft == null) return null;
    final state = draft.effectiveState;
    return PinMark(
      icon: checkStateIcon(state),
      colour: checkStateColor(context, state),
      label: checkStateLabel(l10n, state),
    );
  }
}

/// The raised review flag, and the way to clear it from here.
///
/// It is tappable on this screen and not on the dossier, for the reason the
/// flag exists: the pins sit at the old photo's positions, and the person who
/// can move them to the right ones is the person standing in the room. The
/// visit survives the detour — the recorded nests are held by this screen,
/// which stays under the editor rather than being replaced by it.
class _PinsNeedReview extends StatelessWidget {
  const _PinsNeedReview({required this.area});

  final Area area;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: ZugvogelSpacing.sm),
      child: InkWell(
        onTap: () => unawaited(context.push(Routes.areaEditor(area.id))),
        child: Row(
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
            Icon(
              Icons.chevron_right,
              size: 18,
              color: context.zvColors.warning,
            ),
          ],
        ),
      ),
    );
  }
}

/// One nest, and what this visit has recorded about it so far.
class VisitNestRow extends StatelessWidget {
  const VisitNestRow({
    required this.nest,
    required this.draft,
    required this.onTap,
    super.key,
  });

  final NestState nest;
  final NestCheckDraft? draft;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final recorded = draft;
    final state = recorded?.effectiveState;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        recorded == null
            ? nestSpeciesIcon(nest.species)
            : checkStateIcon(state),
        color: recorded == null
            ? nestSpeciesColor(context, nest.species)
            : checkStateColor(context, state),
      ),
      title: Text(nest.label),
      subtitle: Text(
        // Before it is checked the line says what is IN the nest — which is
        // what tells somebody whether to bother climbing. Afterwards it says
        // what they did, because that is the thing they might want to correct.
        recorded == null
            ? [
                ?nest.positionHint,
                if (nest.isProtected)
                  l10n.nestProtectedDoNotTouch
                else
                  nestContent(l10n, nest),
              ].join(' · ')
            : checkStateLabel(l10n, state),
        style: theme.textTheme.bodySmall?.copyWith(
          color: recorded != null && state == CheckState.partial
              ? context.zvColors.warning
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: recorded == null
          ? Text(
              l10n.visitFlowNestOpen,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : const Icon(Icons.check),
      onTap: onTap,
    );
  }
}
