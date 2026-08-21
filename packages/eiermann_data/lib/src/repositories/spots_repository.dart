import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_data/zugvogel_data.dart';

/// Reads and writes `spots`.
///
/// Deliberately thin. The Spot LIST and the map do not read this collection at
/// all — they read `spot_overview` through `SpotOverviewRepository`, because a
/// row needs contact counts and an urgency rank that only the view has. This
/// repository serves the detail screen and every write.
class SpotsRepository extends PbRepository<Spot> {
  SpotsRepository(PocketBase pb)
    : super(pb: pb, collection: 'spots', fromRecord: Spot.fromRecord);

  /// The body a create or an update sends, with the fields a form owns and
  /// nothing else.
  ///
  /// `next_due_at` is absent on purpose. The collection's update rule refuses
  /// it outright, because a client that can set it can make a Spot look
  /// visited without anybody going there — the one lie this data model must
  /// not be able to tell. Only the rhythm library writes it.
  ///
  /// [org] belongs to the create path only: the update rule refuses it too
  /// (`@request.body.org:isset = false`), since an update rule resolves field
  /// references against the STORED record and would authorise the write
  /// against the old org while landing it in the new one.
  static Map<String, dynamic> body({
    required String name,
    required SpotPhase phase,
    String? street,
    String? postalCode,
    String? city,
    ProspectStage? prospectStage,
    String? accessNote,
    String? note,
    String? org,
  }) => {
    'name': name,
    'phase': phase.wire,
    // The optional text fields are written as '' rather than omitted: an
    // emptied field has to actually clear, and PocketBase reads an absent key
    // as "leave it as it was".
    'street': street ?? '',
    'postal_code': postalCode ?? '',
    'city': city ?? '',
    'access_note': accessNote ?? '',
    'note': note ?? '',
    // Not cleared when null: the Erkundung history stays set after the Spot
    // goes active, so a form that does not offer the field must not wipe it.
    if (prospectStage != null) 'prospect_stage': prospectStage.wire,
    'org': ?org,
  };
}
