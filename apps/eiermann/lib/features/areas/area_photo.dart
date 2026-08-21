import 'dart:async';

import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/areas/areas_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/ui/photo_capture.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_core/zugvogel_core.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// The shape the Bereich photo is shown in.
///
/// Wider than tall, because an overview shot of a room is: a portrait box would
/// letterbox almost every photo. The picture is drawn CONTAINED rather than
/// cropped to fill — the pins go on this image, and a card that hid a third of
/// it would hide nests.
const double _photoAspect = 16 / 10;

/// Which server thumbnail the card asks for. The 1200px generation is the pin
/// editor's working size; asking for the original would send a phone photo of
/// several megabytes down a stairwell connection to draw it 300px wide.
const _photoThumb = '1200x1200';

/// The Bereich's overview photo, or the state that says there is none.
///
/// Tapping an existing photo opens the full-screen viewer, where it can be
/// zoomed — on a phone the card is too small to recognise a rafter in. With no
/// photo the whole box is the button that starts the capture flow, because that
/// is the only useful thing to do with an empty Bereich.
class AreaPhoto extends ConsumerWidget {
  const AreaPhoto({
    required this.area,
    this.onTap,
    this.showAsCanvas = false,
    super.key,
  });

  final Area area;

  /// What tapping the photo does. Null keeps the default: the full-screen
  /// viewer, where the picture can be zoomed.
  final VoidCallback? onTap;

  /// Draw the photo at its OWN aspect ratio, with no tap of its own.
  ///
  /// This is the pin editor's mode, and the shape is the whole point: the
  /// image takes its width from the parent and its height from the picture, so
  /// the box IS the image rect and a normalised coordinate maps onto it
  /// exactly. Inside a box of some other shape, `BoxFit.contain` letterboxes
  /// and every pin sits slightly off.
  final bool showAsCanvas;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    // Read synchronously and tolerate null: the repository is one await behind
    // the first frame, and a card that showed an error tile in the meantime
    // would flicker on every open.
    final repo = ref.watch(areasRepositoryProvider).value;
    final photo = area.photo;

    if (photo == null || repo == null) {
      return _Empty(area: area, unavailable: photo != null);
    }

    if (showAsCanvas) {
      return AreaCanvasPhoto(areaId: area.id, file: photo);
    }

    return Semantics(
      image: true,
      button: true,
      label: l10n.areaPhotoOpenAction,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: AspectRatio(
          aspectRatio: _photoAspect,
          child: Material(
            color: colors.surfaceContainerHighest,
            child: InkWell(
              onTap: onTap ?? () => unawaited(_open(context, repo, photo)),
              child: CachedFileImage(
                url: repo.fileUrl(area.id, photo, thumb: _photoThumb),
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Opens the photo full-screen, at full resolution.
  ///
  /// Not the 1200px thumbnail the card draws: the point of opening it is to
  /// look closely, and a thumbnail blown up is the one thing that cannot
  /// answer "is that the same beam".
  Future<void> _open(
    BuildContext context,
    AreasRepository repo,
    String photo,
  ) => showImageViewer(
    context,
    imageUrls: [repo.fileUrl(area.id, photo).toString()],
  );
}

/// One Bereich photo drawn as a pin canvas: width from the parent, height from
/// the picture.
///
/// The shape is the whole point, which is why this is a widget and not a branch
/// inside a card: the box IS the image rect, so a normalised coordinate maps
/// onto it exactly. Inside a box of some other shape `BoxFit.contain`
/// letterboxes, the bars belong to the box, and every pin sits slightly off.
///
/// Takes a file NAME rather than an [Area], because the review pass draws two
/// of them from one record — the current photo and the outgoing one.
class AreaCanvasPhoto extends ConsumerWidget {
  const AreaCanvasPhoto({
    required this.areaId,
    required this.file,
    super.key,
  });

  final String areaId;

  /// The stored filename, from `photo` or from `previous_photo`.
  final String file;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(areasRepositoryProvider).value;
    if (repo == null) return const LoadingView();
    // `double.infinity` is NOT an option for the width: it also sizes the
    // decode, and `Infinity.round()` throws — measured, as a red test.
    return LayoutBuilder(
      builder: (context, constraints) => CachedFileImage(
        url: repo.fileUrl(areaId, file, thumb: _photoThumb),
        width: constraints.hasBoundedWidth ? constraints.maxWidth : null,
        fit: BoxFit.fitWidth,
      ),
    );
  }
}

/// The no-photo state: the whole box is the way to fix it.
class _Empty extends ConsumerWidget {
  const _Empty({required this.area, required this.unavailable});

  final Area area;

  /// A photo exists but its URL cannot be built yet (the repository is still
  /// resolving). Then this box is a placeholder, not an invitation to replace
  /// what is already there.
  final bool unavailable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return AspectRatio(
      aspectRatio: _photoAspect,
      child: Material(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: unavailable
              ? null
              : () => unawaited(changeAreaPhoto(context, ref, area: area)),
          child: Center(
            child: unavailable
                ? const LoadingView()
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.add_a_photo_outlined,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(height: ZugvogelSpacing.sm),
                      Text(
                        l10n.areaPhotoMissing,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: ZugvogelSpacing.xs),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: ZugvogelSpacing.md,
                        ),
                        child: Text(
                          // Says what the photo is FOR. Without it the missing
                          // photo reads as a cosmetic gap, and it is the reason
                          // a nest cannot be marked at all.
                          l10n.areaPhotoMissingHint,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// Takes or picks a photo for [area], crops it, and uploads it.
///
/// The picking and cropping are shared (see [capturePhoto]); what is specific
/// here is that the upload happens AT ONCE. A Bereich exists to carry this
/// photo, so there is nothing to stage it against — unlike a nest photo, which
/// waits for the sheet's save.
Future<void> changeAreaPhoto(
  BuildContext context,
  WidgetRef ref, {
  required Area area,
}) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final repo = await ref.read(areasRepositoryProvider.future);
  if (!context.mounted) return;

  final photo = await capturePhoto(context, ref, filenameStem: 'bereich');
  // Backing out at any step cancels the whole change — the previous photo (or
  // none) stands, and nothing has been uploaded at this point.
  if (photo == null) return;

  try {
    await repo.updateWithFiles(
      area.id,
      {'photo_taken_at': photo.takenAt.toIso8601String()},
      [photoPart('photo', photo)],
    );
  } on RepositoryException catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text(errorMessage(EiermannStrings(l10n), e))),
    );
    return;
  } on Object catch (e, stackTrace) {
    reportCaughtError(e, stackTrace, context: 'upload area photo ${area.id}');
    messenger.showSnackBar(
      SnackBar(content: Text(errorMessage(EiermannStrings(l10n), e))),
    );
    return;
  }

  ref
    ..invalidate(areasForSpotProvider(area.spot))
    // The editor reads the ONE Bereich, the dossier reads the list of them.
    // Refreshing only the list would leave a reader who replaced the photo from
    // inside the editor looking at the old one.
    ..invalidate(areaProvider(area.id));
}
