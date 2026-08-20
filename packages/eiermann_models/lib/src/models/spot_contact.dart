import 'package:eiermann_models/src/enums.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

part 'spot_contact.freezed.dart';

/// A contact person for a Spot — the caretaker, the owner, the tenant.
///
/// This model plus `Spot.accessNote` IS the handover. It is also the app's only
/// third-party PII, which is why nothing here may be copied into the audit log:
/// a copy in an append-only table outlives the cascade that removes the
/// contact with its Spot.
@freezed
abstract class SpotContact with _$SpotContact {
  const factory SpotContact({
    required String id,
    required String name,
    String? org,
    String? spot,
    ContactRole? role,
    String? phone,
    String? email,
    String? note,
    @Default(false) bool isPrimary,
    DateTime? created,
    DateTime? updated,
  }) = _SpotContact;

  factory SpotContact.fromRecord(RecordModel r) => SpotContact(
    id: r.id,
    name: pbString(r.data['name']) ?? '',
    org: pbString(r.data['org']),
    spot: pbString(r.data['spot']),
    role: ContactRole.fromWire(r.data['role']),
    phone: pbString(r.data['phone']),
    email: pbString(r.data['email']),
    note: pbString(r.data['note']),
    isPrimary: pbBool(r.data['is_primary']),
    created: pbDate(r.data['created']),
    updated: pbDate(r.data['updated']),
  );
}
