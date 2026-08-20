import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

part 'organisation.freezed.dart';

/// The tenant. One row is seeded; the schema is multi-tenant so a second is a
/// row, not a migration.
///
/// `settings` is deliberately NOT mapped here. It is the only JSON field in the
/// whole database and it has exactly one reader — the server's `zv_org.js`.
/// `record.get()` on a JSON field hands JS a byte array, so every property
/// access silently reads `undefined` and falls through to a default; reading it
/// in a second place is how that trap gets sprung again (federfall-jumi).
@freezed
abstract class Organisation with _$Organisation {
  const factory Organisation({
    required String id,
    required String name,
    String? contact,
  }) = _Organisation;

  factory Organisation.fromRecord(RecordModel r) => Organisation(
    id: r.id,
    name: pbString(r.data['name']) ?? '',
    contact: pbString(r.data['contact']),
  );
}
