import 'package:eiermann_models/src/enums.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

part 'spot.freezed.dart';

/// One building, one address, one dossier — the centre of the product.
///
/// [phase] is `required` in the collection yet nullable here, and so is every
/// other select: `fromWire` answers null for a value this build does not know,
/// which turns a server that gained a new phase into one unreadable field
/// rather than a crashed list.
///
/// [nextDueAt] is derived but stored, and the collection's update rule refuses
/// it from a client — only the rhythm library writes it. Read it, never send
/// it: a client that can set it can make a Spot look visited without anyone
/// going there.
@freezed
abstract class Spot with _$Spot {
  const factory Spot({
    required String id,
    required String name,
    String? org,
    String? street,
    String? postalCode,
    String? city,
    GeoPoint? geo,
    @Default(false) bool geoConfirmed,
    SpotPhase? phase,
    ProspectStage? prospectStage,
    DateTime? pausedUntil,
    String? pauseReason,
    ClosedReason? closedReason,
    DateTime? closedAt,
    String? accessNote,
    String? note,
    String? facadePhoto,
    DateTime? nextDueAt,
    DateTime? created,
    DateTime? updated,
  }) = _Spot;

  factory Spot.fromRecord(RecordModel r) => Spot(
    id: r.id,
    name: pbString(r.data['name']) ?? '',
    org: pbString(r.data['org']),
    street: pbString(r.data['street']),
    postalCode: pbString(r.data['postal_code']),
    city: pbString(r.data['city']),
    // Never read raw: PocketBase has no null for a geoPoint, so an un-pinned
    // Spot arrives as {lon: 0, lat: 0} — a real place in the Gulf of Guinea,
    // and therefore a plausible-looking marker instead of missing data.
    geo: GeoPoint.fromPb(r.data['geo']),
    geoConfirmed: pbBool(r.data['geo_confirmed']),
    phase: SpotPhase.fromWire(r.data['phase']),
    prospectStage: ProspectStage.fromWire(r.data['prospect_stage']),
    pausedUntil: pbDate(r.data['paused_until']),
    pauseReason: pbString(r.data['pause_reason']),
    closedReason: ClosedReason.fromWire(r.data['closed_reason']),
    closedAt: pbDate(r.data['closed_at']),
    accessNote: pbString(r.data['access_note']),
    note: pbString(r.data['note']),
    // A single-file field, so the raw value is one filename or the empty
    // string. Protected on the server — building the URL needs a file token.
    facadePhoto: pbString(r.data['facade_photo']),
    nextDueAt: pbDate(r.data['next_due_at']),
    created: pbDate(r.data['created']),
    updated: pbDate(r.data['updated']),
  );
}

/// The address as one line, or null when no part of it was recorded.
///
/// Lives on the model rather than in each screen because the Spot list, the
/// detail header and the map callout all show the same line, and a Spot whose
/// street is empty must not render as a stray comma.
extension SpotAddress on Spot {
  String? get addressLine => formatAddressLine(
    street: street,
    postalCode: postalCode,
    city: city,
  );
}

/// Joins the address parts the way a German address is written: street on the
/// first half, postcode and city on the second, and nothing at all when every
/// part is missing.
String? formatAddressLine({
  String? street,
  String? postalCode,
  String? city,
}) {
  final place = [postalCode, city].whereType<String>().join(' ');
  final parts = [
    ?street,
    if (place.isNotEmpty) place,
  ];
  return parts.isEmpty ? null : parts.join(', ');
}
