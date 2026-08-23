import 'package:eiermann_models/src/enums.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

part 'app_user.freezed.dart';

/// A team member.
@freezed
abstract class AppUser with _$AppUser {
  const factory AppUser({
    required String id,
    required String email,
    String? name,
    String? phone,
    UserRole? role,
    String? org,
    @Default(true) bool isActive,

    /// Whether this account has ever confirmed its address.
    ///
    /// Set by PocketBase when somebody completes a password reset, which for an
    /// invited account is the moment they first set their own password. So on
    /// the roster it reads as "the invitation was picked up" — an invited
    /// member who never did is otherwise indistinguishable from one who is
    /// simply quiet.
    ///
    /// Defaults to false, unlike [isActive]: an account the server did not
    /// report a value for has not demonstrated anything, and claiming it had
    /// would hide exactly the row worth chasing.
    @Default(false) bool verified,
    String? invitedBy,
    DateTime? created,
  }) = _AppUser;

  factory AppUser.fromRecord(RecordModel r) => AppUser(
    id: r.id,
    email: pbString(r.data['email']) ?? '',
    name: pbString(r.data['name']),
    phone: pbString(r.data['phone']),
    role: UserRole.fromWire(r.data['role']),
    org: pbString(r.data['org']),
    // Absent reads as ACTIVE only because the collection defaults it to true
    // and the server never returns a row without it. Reading a missing flag as
    // "deactivated" would lock out every user the moment a projection dropped
    // the column.
    isActive: !r.data.containsKey('is_active') || pbBool(r.data['is_active']),
    verified: pbBool(r.data['verified']),
    invitedBy: pbString(r.data['invited_by']),
    created: pbDate(r.data['created']),
  );
}
