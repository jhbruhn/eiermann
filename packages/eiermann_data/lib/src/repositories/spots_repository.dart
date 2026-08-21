import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_core/zugvogel_core.dart';
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
  /// [geo] and [geoConfirmed] travel together on purpose — see the parameter
  /// docs below.
  static Map<String, dynamic> body({
    required String name,
    required SpotPhase? phase,
    String? street,
    String? postalCode,
    String? city,
    ProspectStage? prospectStage,
    String? accessNote,
    String? note,
    String? org,
    GeoPoint? geo,
    bool geoConfirmed = false,
  }) => {
    'name': name,
    // Omitted when null, which is the EDIT path for a Spot whose stored phase
    // this build has no name for. PocketBase reads an absent key as "leave it
    // as it was", so omitting preserves a phase the client cannot spell —
    // whereas
    // sending a default would quietly rewrite a fifth phase the server gained
    // into `prospect`. Required-but-nullable so a caller has to decide rather
    // than forget: a CREATE without one is a 400, since the column is required.
    if (phase != null) 'phase': phase.wire,
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
    // Omitted when there is no pin rather than written as {0, 0}. PocketBase
    // has no null for a geoPoint, so the two are the same thing on the wire —
    // but a form that has not resolved a pin yet must not overwrite one another
    // screen placed, and the map picker is a separate step from this form.
    if (geo != null) ...{
      'geo': geo.toPb(),
      // Only ever alongside a pin, and only ever the truth about THAT pin. A
      // geocoder's guess can sit on the wrong side of a courtyard, which sends
      // the next person to the wrong door; the flag is what makes the guess
      // legible as one, so it must never ride along with a pin somebody did not
      // look at.
      'geo_confirmed': geoConfirmed,
    },
  };

  /// The body ONE PHASE TRANSITION sends: the phase, and the fields that
  /// transition has to carry.
  ///
  /// Separate from [body] because [body] is a *form's* body — it writes
  /// every field the form owns, empty ones included, so that clearing a
  /// field actually clears it. Routing a phase change through it would wipe
  /// the address off a Spot somebody only meant to pause.
  ///
  /// The reasons are sent as `''` rather than omitted when the target IS the
  /// phase they belong to: re-editing a pause has to be able to remove its
  /// planned end date, and PocketBase reads an absent key as "leave it as it
  /// was". For any other target they are left out entirely — the lifecycle hook
  /// clears them itself, and a client that also cleared them would be a second
  /// copy of that rule, drifting the day one of the two changes.
  ///
  /// [prospectStage] belongs to one move: activating an Erkundung that has not
  /// recorded its yes yet. The server refuses `prospect -> active` without it.
  static Map<String, dynamic> phaseBody({
    required SpotPhase phase,
    String? pauseReason,
    DateTime? pausedUntil,
    ClosedReason? closedReason,
    ProspectStage? prospectStage,
  }) => {
    'phase': phase.wire,
    if (phase == SpotPhase.paused) ...{
      'pause_reason': pauseReason ?? '',
      'paused_until': pausedUntil?.toUtc().toIso8601String() ?? '',
    },
    if (phase == SpotPhase.closed) 'closed_reason': closedReason?.wire ?? '',
    if (prospectStage != null) 'prospect_stage': prospectStage.wire,
  };
}
