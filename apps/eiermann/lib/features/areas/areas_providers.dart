import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:image_picker/image_picker.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'areas_providers.g.dart';

/// The Bereiche of one Spot, in walking order.
///
/// Unpaged, because a building has a handful and the dossier shows all of them
/// — the order is physical (ground floor, then the attic), so there is no
/// "first page" that would mean anything on its own.
@riverpod
Future<List<Area>> areasForSpot(Ref ref, String spotId) async {
  final repo = await ref.watch(areasRepositoryProvider.future);
  return repo.forSpot(spotId);
}

/// Injectable image source, so a widget test can supply a fake picker.
///
/// A test cannot open a camera, and the photo flow is exactly the part worth
/// testing: pick, crop, upload, and what happens when somebody backs out
/// halfway.
@riverpod
ImagePicker imagePicker(Ref ref) => ImagePicker();
