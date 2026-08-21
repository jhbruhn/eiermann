import 'dart:typed_data';

import 'package:eiermann/features/areas/areas_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// A photo the user has taken and cropped, ready to upload.
typedef CapturedPhoto = ({Uint8List bytes, String filename, DateTime takenAt});

/// Asks for a source, picks a photo, and crops it — the two steps every photo
/// in this app goes through before it is worth anything.
///
/// Returns null whenever the user backed out, at any step: no source chosen, no
/// photo taken, or the crop dismissed. A caller must treat that as "nothing
/// changed" rather than as an empty photo.
///
/// Everything `ref`- and `context`-dependent is read BEFORE the first await.
/// The camera can dispose the calling element while it is in the foreground
/// (Android backgrounds the activity), and a `ref` touched afterwards throws
/// while the photo the user just took is still in hand. The navigator is
/// captured for the same reason: the crop step is pushed after the camera
/// returns, so it cannot depend on that element still being mounted.
///
/// The crop is free-form. A locked rectangle would force somebody to cut the
/// rafter they are photographing out of the frame, and nothing downstream
/// depends on a shape: the Bereich photo carries normalised pins, and a nest
/// photo is looked at rather than measured.
Future<CapturedPhoto?> capturePhoto(
  BuildContext context,
  WidgetRef ref, {
  required String filenameStem,
}) async {
  final l10n = context.l10n;
  final picker = ref.read(imagePickerProvider);
  final navigator = Navigator.of(context, rootNavigator: true);

  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    showDragHandle: true,
    builder: (_) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(l10n.photoCameraAction),
            onTap: () => Navigator.pop(context, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(l10n.photoGalleryAction),
            onTap: () => Navigator.pop(context, ImageSource.gallery),
          ),
        ],
      ),
    ),
  );
  if (source == null) return null;

  final shot = await picker.pickImage(source: source);
  if (shot == null) return null;

  final cropped = await showImageCropper(
    navigator,
    bytes: await shot.readAsBytes(),
  );
  if (cropped == null) return null;

  return (
    bytes: cropped,
    // The crop always re-encodes as JPEG, so the picked name's extension may no
    // longer describe the bytes.
    filename: '$filenameStem.jpg',
    takenAt: await _takenAt(shot),
  );
}

/// The photo as a multipart part on [field].
http.MultipartFile photoPart(String field, CapturedPhoto photo) =>
    http.MultipartFile.fromBytes(field, photo.bytes, filename: photo.filename);

/// When the picked photo was taken, as far as the file knows.
///
/// Not "now": a gallery pick can be from last week's visit, and the crop
/// re-encodes and drops EXIF, so it has to be read off the ORIGINAL file.
/// Falls back to now — a camera shot reports no timestamp on some platforms,
/// and the moment it was handed over is then the best answer available.
Future<DateTime> _takenAt(XFile shot) async {
  try {
    return (await shot.lastModified()).toUtc();
  } on Object {
    return DateTime.now().toUtc();
  }
}
