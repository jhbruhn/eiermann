import 'dart:async';

import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/areas/areas_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
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
  const AreaPhoto({required this.area, super.key});

  final Area area;

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
              onTap: () => unawaited(_open(context, repo, photo)),
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
/// Everything `ref`- and `context`-dependent is read BEFORE the first await:
/// the camera can dispose this element while it is in the foreground (Android
/// backgrounds the activity), and a `ref` touched afterwards throws while the
/// photo the user just took is still in hand. The navigator is captured for the
/// same reason — the crop step is pushed after the camera returns.
Future<void> changeAreaPhoto(
  BuildContext context,
  WidgetRef ref, {
  required Area area,
}) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final picker = ref.read(imagePickerProvider);
  final navigator = Navigator.of(context, rootNavigator: true);
  final repo = await ref.read(areasRepositoryProvider.future);
  if (!context.mounted) return;

  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    showDragHandle: true,
    builder: (_) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(l10n.areaPhotoCameraAction),
            onTap: () => Navigator.pop(context, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(l10n.areaPhotoGalleryAction),
            onTap: () => Navigator.pop(context, ImageSource.gallery),
          ),
        ],
      ),
    ),
  );
  if (source == null) return;

  final shot = await picker.pickImage(source: source);
  if (shot == null) return;

  // Free-form crop: a Bereich is whatever shape the room is, and a locked
  // rectangle would force somebody to cut a rafter out of the frame. Pins are
  // normalised to the image, so no aspect ratio is more correct than another.
  final cropped = await showImageCropper(
    navigator,
    bytes: await shot.readAsBytes(),
  );
  // Backing out of the crop cancels the whole change — the previous photo (or
  // none) stands. Nothing has been uploaded at this point.
  if (cropped == null) return;

  try {
    await repo.updateWithFiles(
      area.id,
      // When the photo was TAKEN, which is not always now: a gallery pick can
      // be from last week's visit, and the file's own timestamp is the closest
      // honest answer. The crop re-encodes and drops EXIF, so it has to be read
      // from the original file rather than from the bytes being uploaded.
      {'photo_taken_at': (await _takenAt(shot)).toIso8601String()},
      [
        http.MultipartFile.fromBytes(
          'photo',
          cropped,
          // The crop always re-encodes as JPEG, so the picked name's extension
          // may no longer describe the bytes.
          filename: _croppedName(shot.name),
        ),
      ],
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

  ref.invalidate(areasForSpotProvider(area.spot));
}

/// When the picked photo was taken, as far as the file knows.
///
/// Falls back to now: a camera shot on some platforms reports no timestamp at
/// all, and the moment it was handed over is then the best available answer.
Future<DateTime> _takenAt(XFile shot) async {
  try {
    return (await shot.lastModified()).toUtc();
  } on Object {
    return DateTime.now().toUtc();
  }
}

/// The upload filename: the picked stem with a `.jpg` extension, because the
/// crop step re-encodes every photo as JPEG.
String _croppedName(String picked) {
  final stem = picked.isEmpty
      ? 'bereich'
      : picked.split('/').last.split('.').first;
  return '${stem.isEmpty ? 'bereich' : stem}.jpg';
}
