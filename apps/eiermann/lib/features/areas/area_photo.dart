import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/areas/areas_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/ui/photo_capture.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_core/zugvogel_core.dart';
import 'package:zugvogel_pb_client/zugvogel_pb_client.dart';
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
/// Which is also why the height cannot simply be constrained while the picture
/// is on its way: a minimum height would make the box TALLER than a panorama
/// shot and drift every pin upwards. So the box is reserved at the card's
/// shape ([_photoAspect]) and handed over to the picture the moment the
/// picture can size it. Before that the canvas collapsed to
/// nothing and jumped open on arrival, which on the visit flow moved the nest
/// rows under somebody's finger.
///
/// Takes a file NAME rather than an [Area], because the review pass draws two
/// of them from one record — the current photo and the outgoing one.
class AreaCanvasPhoto extends ConsumerStatefulWidget {
  const AreaCanvasPhoto({
    required this.areaId,
    required this.file,
    super.key,
  });

  final String areaId;

  /// The stored filename, from `photo` or from `previous_photo`.
  final String file;

  @override
  ConsumerState<AreaCanvasPhoto> createState() => _AreaCanvasPhotoState();
}

class _AreaCanvasPhotoState extends ConsumerState<AreaCanvasPhoto> {
  /// Whether the picture is decoded, and can therefore size its own box.
  ///
  /// Until it is, the reserved box stands. It is never set from the stream's
  /// ERROR path on purpose: a photo that cannot be fetched keeps the reserved
  /// shape, so the retry and the broken-image tile have a box to sit in
  /// instead of the layout collapsing a second time.
  bool _sized = false;

  ImageStream? _stream;

  late final ImageStreamListener _listener = ImageStreamListener(
    (_, _) => _onSized(),
    // Swallowed rather than left to the default handler, which would report it
    // as an unhandled framework error. The failure itself is not lost: the
    // image widget below is on the same stream and owns the retry and the
    // placeholder.
    onError: (_, _) {},
  );

  void _onSized() {
    if (_sized || !mounted) return;
    setState(() => _sized = true);
  }

  @override
  void didUpdateWidget(AreaCanvasPhoto old) {
    super.didUpdateWidget(old);
    // A different picture is a different shape, so the reservation starts over.
    if (old.file != widget.file || old.areaId != widget.areaId) {
      _stream?.removeListener(_listener);
      _stream = null;
      _sized = false;
    }
  }

  /// Attaches to [provider]'s stream, unless it is the one already attached.
  ///
  /// Called from a post-frame callback, never from `build`: for a picture
  /// already in the image cache the listener fires SYNCHRONOUSLY, and that is
  /// the good case — a `setState` in the middle of a build is not.
  void _watch(ImageProvider<Object> provider) {
    final stream = provider.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(areasRepositoryProvider).value;
    // The reserved shape holds here too: the repository is one await behind the
    // first frame, and a zero-height spinner would move everything under it
    // twice instead of once.
    if (repo == null) {
      return const _ReservedBox(child: LoadingView());
    }
    final url = repo.fileUrl(widget.areaId, widget.file, thumb: _photoThumb);

    // `double.infinity` is NOT an option for the width: it also sizes the
    // decode, and `Infinity.round()` throws — measured, as a red test.
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth ? constraints.maxWidth : null;
        if (!_sized && width != null) {
          final provider = _provider(context, url, width);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _watch(provider);
          });
        }
        final image = CachedFileImage(
          url: url,
          width: width,
          fit: BoxFit.fitWidth,
        );
        return _sized ? image : _ReservedBox(child: image);
      },
    );
  }

  /// The image as [CachedFileImage] will ask for it — same cache key, same
  /// decode width.
  ///
  /// Deliberately identical, because then this is not a second load at all:
  /// the widget below resolves first, this joins the entry it created, and the
  /// frame that flips [_sized] is the frame that can already paint. If the
  /// shared widget ever changes how it sizes its decode, the two drift into two
  /// entries — which costs a decode and a frame, and gets no pin wrong.
  ImageProvider<Object> _provider(BuildContext context, Uri url, double width) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return ResizeImage.resizeIfNeeded(
      (width * dpr).round(),
      null,
      CachedNetworkImageProvider(
        url.toString(),
        cacheKey: fileCacheKey(url),
        cacheManager: ref.read(protectedFileCacheManagerProvider),
      ),
    );
  }
}

/// The space a Bereich photo takes before it can take its own.
///
/// The card's shape rather than a guess of its own: an overview shot of a room
/// is wider than tall, so this is the smallest jump available without knowing
/// the picture. Knowing it would mean storing the ratio on the Bereich at
/// upload — worth doing, and not needed to stop the collapse.
class _ReservedBox extends StatelessWidget {
  const _ReservedBox({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: _photoAspect,
    child: ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: child,
    ),
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
