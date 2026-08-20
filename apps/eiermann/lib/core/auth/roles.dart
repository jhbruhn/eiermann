import 'package:eiermann_models/eiermann_models.dart';

/// What a role may do, in one place.
///
/// Two roles, not four. The concept is explicit that this is a small team where
/// everybody does the field work: a `member` walks the tour and records what
/// they found, and a `coordinator` additionally decides the things that are
/// hard to undo. Inventing a read-only role would be inventing a person who
/// does not exist here.
///
/// These are the CLIENT's copy of the rules. The server enforces its own in the
/// collection access rules and in its hooks — this only decides what to show,
/// so a member never taps an action that would come back 403. Any check that
/// matters exists in both places, on purpose.
extension RolePermissions on UserRole {
  /// Whether this role may do the ordinary field work: record a visit, swap
  /// eggs, add a nest, write a finding.
  bool get canRecordFieldwork => true;

  /// Whether this role may delete a record rather than closing or pausing it.
  ///
  /// Deleting a Spot destroys its whole dossier — the Erkundung history, every
  /// visit, every check. Closing it keeps all of that and is what somebody
  /// actually wants nine times out of ten, which is why the destructive route
  /// is the coordinator's.
  bool get canDelete => this == UserRole.coordinator;

  /// Whether this role may override the rhythm or a stored due date by hand.
  bool get canOverrideRhythm => this == UserRole.coordinator;

  /// Whether this role may move a nest OUT of `protected`.
  ///
  /// The way INTO protected is open to everybody — seeing a protected species
  /// and saying so must never be gated. The way out is not: it re-enables egg
  /// removal on that nest, which is the one action here that can be illegal.
  bool get canUnprotect => this == UserRole.coordinator;

  /// Whether this role may manage the team, read the audit log, or export.
  bool get canAdminister => this == UserRole.coordinator;
}
