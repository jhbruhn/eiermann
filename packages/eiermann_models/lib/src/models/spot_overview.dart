import 'package:eiermann_models/src/enums.dart';
import 'package:eiermann_models/src/models/spot.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

part 'spot_overview.freezed.dart';

/// One row of the Spot list and one pin on the map, from the `spot_overview`
/// view: the Spot plus its contact counts and an urgency rank.
///
/// The whole point is that a list screen fires ONE query. Fetching spots and
/// then counting contacts per row is three round trips and a rebuild storm,
/// which is what makes an app feel broken on a phone in a stairwell.
///
/// Not every Spot column is here — the view carries what a row and a pin draw,
/// so `note`, `pause_reason` and `closed_at` are deliberately absent. The
/// detail screen reads the full [Spot].
@freezed
abstract class SpotOverview with _$SpotOverview {
  const factory SpotOverview({
    required String id,
    required String name,

    /// The view's CASE rank, 0 (overdue) to 6 (closed). Kept as the raw int
    /// because it is what the list sorts and keyset-pages by; [level] names it.
    required int urgency,
    String? org,
    String? street,
    String? postalCode,
    String? city,
    GeoPoint? geo,
    @Default(false) bool geoConfirmed,
    SpotPhase? phase,
    ProspectStage? prospectStage,
    DateTime? pausedUntil,
    ClosedReason? closedReason,
    String? accessNote,
    String? facadePhoto,
    DateTime? nextDueAt,
    @Default(0) int contactCount,
    @Default(0) int primaryContactCount,
    DateTime? created,
    DateTime? updated,
  }) = _SpotOverview;

  factory SpotOverview.fromRecord(RecordModel r) => SpotOverview(
    id: r.id,
    name: pbString(r.data['name']) ?? '',
    // PocketBase types a view's columns by inference, and a COMPUTED column
    // comes back as `json` — so the three counted columns here may arrive as
    // string-encoded numbers rather than numbers. `pbInt` tolerates both;
    // nothing may interpolate these into a label raw.
    //
    // An unreadable rank falls back to "active, not due yet" rather than to 0:
    // reading a rank the app cannot parse as OVERDUE would paint the loudest
    // colour on the list over a parsing accident, and a colour that is always
    // red is one people stop reading.
    urgency: pbInt(r.data['urgency']) ?? SpotUrgency.inRhythm.rank,
    org: pbString(r.data['org']),
    street: pbString(r.data['street']),
    postalCode: pbString(r.data['postal_code']),
    city: pbString(r.data['city']),
    geo: GeoPoint.fromPb(r.data['geo']),
    geoConfirmed: pbBool(r.data['geo_confirmed']),
    phase: SpotPhase.fromWire(r.data['phase']),
    prospectStage: ProspectStage.fromWire(r.data['prospect_stage']),
    pausedUntil: pbDate(r.data['paused_until']),
    closedReason: ClosedReason.fromWire(r.data['closed_reason']),
    accessNote: pbString(r.data['access_note']),
    facadePhoto: pbString(r.data['facade_photo']),
    nextDueAt: pbDate(r.data['next_due_at']),
    contactCount: pbInt(r.data['contact_count']) ?? 0,
    primaryContactCount: pbInt(r.data['primary_contact_count']) ?? 0,
    created: pbDate(r.data['created']),
    updated: pbDate(r.data['updated']),
  );
}

/// The derived reads a row needs.
extension SpotOverviewDerived on SpotOverview {
  /// [urgency] as a name the UI can switch over exhaustively, or null for a
  /// rank this build has no name for.
  SpotUrgency? get level => SpotUrgency.fromRank(urgency);

  /// The address as one line, or null when none was recorded.
  String? get addressLine => formatAddressLine(
    street: street,
    postalCode: postalCode,
    city: city,
  );
}
