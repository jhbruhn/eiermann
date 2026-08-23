import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';

/// The role words, in one place.
///
/// Nullable, and answering for null too: `role` is genuinely nullable in the
/// schema — that is the state an account is in between existing and being let
/// in — and a row that rendered it as the nearest known role would say
/// something untrue about what somebody may do.
String userRoleLabel(AppLocalizations l10n, UserRole? role) => switch (role) {
  UserRole.coordinator => l10n.teamRoleCoordinator,
  UserRole.member => l10n.teamRoleMember,
  // `guest` and null are the same thing to a reader: signed in, not let in.
  // They differ only in how they got there — provisioned by an identity
  // provider, or created before anybody decided — and that difference is the
  // server's business, not the roster's.
  UserRole.guest || null => l10n.teamRolePending,
};

/// The icon beside a role: the second, non-colour signal.
IconData userRoleIcon(UserRole? role) => switch (role) {
  UserRole.coordinator => Icons.shield_outlined,
  UserRole.member => Icons.person_outline,
  UserRole.guest || null => Icons.hourglass_top_outlined,
};

/// What to call somebody in a list.
///
/// The name when there is one, the address otherwise — never an id, and never
/// an empty line. An account is created with a name precisely so this rarely
/// has to fall back, but an OAuth2 provisioning can produce one without.
String userDisplayName(AppLocalizations l10n, AppUser user) {
  final name = user.name?.trim();
  if (name != null && name.isNotEmpty) return name;
  final email = user.email.trim();
  return email.isEmpty ? l10n.teamUnnamed : email;
}
