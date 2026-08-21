import 'dart:async';

import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/areas/area_photo.dart';
import 'package:eiermann/features/areas/areas_providers.dart';
import 'package:eiermann/features/areas/pin_canvas.dart';
import 'package:eiermann/features/nests/nest_labels.dart';
import 'package:eiermann/features/nests/nests_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_core/zugvogel_core.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Below this width the two photos go one above the other.
///
/// A side-by-side comparison of two attic shots on a phone gives each of them
/// half a screen width, which is where "is that the same beam" stops being
/// answerable — and answering it is the entire purpose of this screen.
const double _sideBySideFrom = 700;

/// The forced review pass after a Bereich photo was replaced.
///
/// A pin is a normalised coordinate ON A PHOTO, so a new photo leaves every
/// pin holding the same two numbers while they point somewhere else in the
/// building. The data is intact and every pin is a lie — and the only place
/// that can be resolved is in front of both pictures, which is what this is.
///
/// Two decisions worth stating, because both look like friction:
///
/// * **Every pin is touched once.** Confirming a pin that has not moved writes
///   nothing, so no record of it exists to check — the pass is the client's
///   discipline, not a server invariant. A "everything is fine" bulk button
///   would end it in one tap and there would be no pass at all.
/// * **No new nest until it is over.** Tapping the photo does not create one
///   while the old pins are still wrong; placing a fresh pin against a
///   picture whose other pins are misplaced adds to exactly the confusion
///   being cleared.
class AreaPinReview extends StatelessWidget {
  const AreaPinReview({
    required this.area,
    required this.nests,
    required this.before,
    required this.canvas,
    required this.reviewed,
    required this.onConfirm,
    required this.onFinish,
    this.isFinishing = false,
    super.key,
  });

  final Area area;

  /// The nests of this Bereich, pinned or not. Only pinned ones are reviewable:
  /// a nest that was never placed has no coordinate to have drifted.
  final List<Nest> nests;

  /// The pins AS THEY STOOD when the pass began, drawn on the outgoing photo.
  ///
  /// A snapshot rather than the live rows, and that is the whole value of the
  /// left-hand picture: once a pin has been dragged, the live coordinate is the
  /// corrected one, and the old photo would show the correction instead of what
  /// is being corrected.
  final List<PinnedNest> before;

  /// The interactive canvas over the NEW photo — passed in for the same reason
  /// [PinCanvas] takes its photo that way: the caller owns the writes.
  final Widget canvas;

  /// Ids of the nests confirmed or moved so far in this pass.
  final Set<String> reviewed;

  final ValueChanged<String> onConfirm;
  final VoidCallback onFinish;
  final bool isFinishing;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final pinned = nests.where((nest) => nest.hasPin).toList();
    final done = pinned.where((nest) => reviewed.contains(nest.id)).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(done: done, total: pinned.length),
        const SizedBox(height: ZugvogelSpacing.md),
        LayoutBuilder(
          builder: (context, constraints) {
            final beforeSide = _Captioned(
              caption: l10n.areaPinReviewBefore,
              // The old photo carries the OLD pins and is not touchable: it is
              // a picture of the claim being checked, and a pin that answered a
              // gesture there would write a coordinate onto the new photo from
              // a position measured on the old one.
              child: area.previousPhoto == null
                  ? const _PhotoGone()
                  : PinCanvas(
                      photo: AreaCanvasPhoto(
                        areaId: area.id,
                        file: area.previousPhoto!,
                      ),
                      nests: before,
                      dense: true,
                    ),
            );
            final afterSide = _Captioned(
              caption: l10n.areaPinReviewAfter,
              child: canvas,
            );
            if (constraints.maxWidth >= _sideBySideFrom) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: beforeSide),
                  const SizedBox(width: ZugvogelSpacing.md),
                  Expanded(child: afterSide),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                beforeSide,
                const SizedBox(height: ZugvogelSpacing.md),
                afterSide,
              ],
            );
          },
        ),
        const SizedBox(height: ZugvogelSpacing.md),
        Text(l10n.areaPinReviewLockedHint, style: theme.textTheme.bodySmall),
        const SizedBox(height: ZugvogelSpacing.sm),
        for (final nest in pinned)
          _PinRow(
            nest: nest,
            isReviewed: reviewed.contains(nest.id),
            onConfirm: () => onConfirm(nest.id),
          ),
        const SizedBox(height: ZugvogelSpacing.md),
        PrimaryButton(
          label: l10n.areaPinReviewFinishAction,
          isLoading: isFinishing,
          // Out of reach until every pin has been touched. The progress line
          // above says how far off it is, so a disabled button is never the
          // only feedback.
          onPressed: done == pinned.length ? onFinish : null,
        ),
      ],
    );
  }
}

/// What the pass is and how far along it is.
class _Header extends StatelessWidget {
  const _Header({required this.done, required this.total});

  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final warning = context.zvColors.warning;

    return Card(
      color: warning.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.all(ZugvogelSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_outlined, color: warning),
                const SizedBox(width: ZugvogelSpacing.sm),
                Expanded(
                  child: Text(
                    l10n.areaPinReviewTitle,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Text(
                  l10n.areaPinReviewProgress(done, total),
                  style: theme.textTheme.labelLarge,
                ),
              ],
            ),
            const SizedBox(height: ZugvogelSpacing.sm),
            Text(
              l10n.areaPinReviewExplainer,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

/// One photo under its caption.
///
/// The captions are not decoration: two pictures of the same attic taken a year
/// apart are hard to tell apart, and which one is which decides which way a pin
/// gets dragged.
class _Captioned extends StatelessWidget {
  const _Captioned({required this.caption, required this.child});

  final String caption;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          caption,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: ZugvogelSpacing.xs),
        child,
      ],
    );
  }
}

/// The old photo is gone but the flag still stands.
///
/// Reachable exactly once: the hook drops `previous_photo` when the pass ends,
/// so a Bereich that is flagged without one has been through something nobody
/// designed — a superuser edit, a restored backup. Then the pass still has to
/// be completable, because the alternative is a Bereich that can never lose
/// its warning. Said plainly rather than drawn as a broken image.
class _PhotoGone extends StatelessWidget {
  const _PhotoGone();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      context.l10n.areaPinsNeedReview,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// One nest's line in the pass: its pin, and the one tap that clears it.
class _PinRow extends StatelessWidget {
  const _PinRow({
    required this.nest,
    required this.isReviewed,
    required this.onConfirm,
  });

  final Nest nest;
  final bool isReviewed;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        isReviewed ? Icons.check_circle : nestSpeciesIcon(nest.species),
        color: isReviewed
            ? context.zvColors.good
            : nestSpeciesColor(context, nest.species),
      ),
      title: Text(nest.label),
      // What a pin cannot say, and the only thing that decides where the pin
      // belongs on a picture that no longer matches it.
      subtitle: nest.positionHint == null ? null : Text(nest.positionHint!),
      trailing: isReviewed
          ? Text(
              l10n.areaPinReviewConfirmed,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : TextButton(
              onPressed: onConfirm,
              child: Text(l10n.areaPinReviewConfirmAction),
            ),
    );
  }
}

/// Ends the pass: the flag comes down and the server drops the old photo.
///
/// Returns whether it landed, so the caller keeps its local review state when
/// it did not — clearing the ticks on a failed write would send somebody
/// through the whole pass again for a lost connection.
Future<bool> finishPinReview(
  BuildContext context,
  WidgetRef ref, {
  required Area area,
}) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final repo = await ref.read(areasRepositoryProvider.future);
    await repo.finishPinReview(area.id);
  } on Object catch (error, stackTrace) {
    if (error is! RepositoryException) {
      reportCaughtError(
        error,
        stackTrace,
        context: 'finish pin review ${area.id}',
      );
    }
    messenger.showSnackBar(
      SnackBar(content: Text(errorMessage(EiermannStrings(l10n), error))),
    );
    return false;
  }
  ref
    ..invalidate(areaProvider(area.id))
    // The dossier draws the same flag on its card, and the Bereich it belongs
    // to comes from the list — not from the single read the editor does.
    ..invalidate(areasForSpotProvider(area.spot));
  // The pins themselves were written as they were dragged; this re-read is for
  // the ticks, which live in the editor's state and are dropped with the pass.
  invalidateNestViews(ref);
  return true;
}
