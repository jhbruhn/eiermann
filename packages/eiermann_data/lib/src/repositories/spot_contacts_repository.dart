import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_data/zugvogel_data.dart';

/// Reads and writes `spot_contacts` — the caretaker, the owner, the tenant.
///
/// The rows here are named private individuals with phone numbers: the app's
/// only third-party PII. There is deliberately no retention scrub, because a
/// caretaker's number is needed for exactly as long as the Spot exists; it goes
/// with the Spot, by cascade. Nothing may copy these values anywhere that
/// outlives that cascade — the audit log in particular.
class SpotContactsRepository extends PbRepository<SpotContact> {
  SpotContactsRepository(PocketBase pb)
    : super(
        pb: pb,
        collection: 'spot_contacts',
        fromRecord: SpotContact.fromRecord,
      );

  /// Every contact of one Spot, the ones worth ringing first at the top.
  ///
  /// Unpaged: a building has a handful of contacts, and the detail screen shows
  /// all of them. The sort is the server's — `-is_primary` puts true first,
  /// SQLite storing it as 1.
  Future<List<SpotContact>> forSpot(String spotId) => list(
    filter: filterExpr('spot = {:spot}', {'spot': spotId}),
    sort: '-is_primary,name',
  );

  /// The body a create or an update sends.
  ///
  /// [spot] belongs to the create path only: the collection freezes the parent
  /// on update, because an update rule resolves `spot` against the STORED
  /// record and a re-parenting write would be authorised against the old Spot
  /// while landing on the new one.
  static Map<String, dynamic> body({
    required String name,
    required ContactRole role,
    String? phone,
    String? email,
    String? note,
    bool isPrimary = false,
    String? spot,
    String? org,
  }) => {
    'name': name,
    'role': role.wire,
    'phone': phone ?? '',
    'email': email ?? '',
    'note': note ?? '',
    'is_primary': isPrimary,
    'spot': ?spot,
    'org': ?org,
  };
}
