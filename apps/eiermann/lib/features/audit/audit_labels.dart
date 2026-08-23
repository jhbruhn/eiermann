import 'package:eiermann/features/spots/spot_labels.dart';
import 'package:eiermann/features/team/team_labels.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';

/// The client half of the audit registry: every wire value, as a word.
///
/// **This file is a contract, and `eiermann-uwd.4` is what enforces it.** That
/// guard parses `ACTIONS` and `FIELDS` out of `app_audit.js` and fails on any
/// entry that would render as its raw column name — in EITHER language. A log
/// row reading "base_interval_days: 7 → 10" is a row written for whoever wrote
/// the schema rather than for whoever has to read it.
///
/// The server sends wire values for the same reason it sends refusal codes: it
/// does not know which language the reader speaks, and these rows outlive any
/// sentence written into them. A German string stored in 2026 is untranslatable
/// in 2027 and simply wrong to an English reader.
///
/// Adding an action or a field is additive — nothing already recorded changes
/// meaning — so it ships as `feat`. Renaming one is a wire change, exactly like
/// renaming an enum's wire value, and the rows already written keep the old
/// spelling forever.

/// What happened, as a sentence fragment: "hat den Zugang beendet".
///
/// Unknown actions fall back to the raw value rather than to nothing. A log
/// with a blank line in it is a log that has silently lost an entry; a log with
/// an untranslated one visibly needs a label, which is the honest failure and
/// the one the guard test turns into a red build.
String auditActionLabel(AppLocalizations l10n, String action) =>
    switch (action) {
      'spot_phase_changed' => l10n.auditActionSpotPhaseChanged,
      'spot_deleted' => l10n.auditActionSpotDeleted,
      'nest_protected' => l10n.auditActionNestProtected,
      'nest_unprotected' => l10n.auditActionNestUnprotected,
      'nest_deleted' => l10n.auditActionNestDeleted,
      'user_invited' => l10n.auditActionUserInvited,
      'user_role_changed' => l10n.auditActionUserRoleChanged,
      'user_access_changed' => l10n.auditActionUserAccessChanged,
      'user_provisioned' => l10n.auditActionUserProvisioned,
      'rhythm_changed' => l10n.auditActionRhythmChanged,
      'report_exported' => l10n.auditActionReportExported,
      _ => action,
    };

/// The column that changed, as a word: `base_interval_days` → "Grundfrist".
String auditFieldLabel(AppLocalizations l10n, String field) => switch (field) {
  'phase' => l10n.auditFieldPhase,
  'closed_reason' => l10n.auditFieldClosedReason,
  'paused_until' => l10n.auditFieldPausedUntil,
  'status' => l10n.auditFieldStatus,
  'species' => l10n.auditFieldSpecies,
  'species_label' => l10n.auditFieldSpeciesLabel,
  'role' => l10n.auditFieldRole,
  'is_active' => l10n.auditFieldIsActive,
  'base_interval_days' => l10n.rhythmBaseLabel,
  'empty_checks_per_step' => l10n.rhythmPerStepLabel,
  'interval_steps' => l10n.rhythmLadderLabel,
  'half_clutch_return_days' => l10n.rhythmHalfClutchLabel,
  'pause_auto_resume' => l10n.rhythmAutoResumeLabel,
  _ => field,
};

/// A stored value, in whatever vocabulary its field belongs to.
///
/// The point of routing through the EXISTING label functions rather than a
/// second table of strings: `closed` has to read the same word here as it does
/// on the Spot's own phase chip. Two vocabularies for one enum drift, and the
/// log is where that drift is least noticeable and most damaging — nobody
/// cross-checks a log against a screen.
///
/// An empty value is not "unknown": it is the absence of a previous value, and
/// the caller says so with its own copy (see [AuditEntry.hasNoPrevious]).
String auditValueLabel(AppLocalizations l10n, String field, String value) {
  if (value.isEmpty) return value;
  return switch (field) {
    'phase' => spotPhaseLabel(l10n, SpotPhase.fromWire(value)),
    'role' => userRoleLabel(l10n, UserRole.fromWire(value)),
    // A bool arrives as the string SQLite stored. Rendered as a word, because
    // "is_active: false → true" is a row that makes the reader do the mapping.
    'is_active' || 'pause_auto_resume' =>
      value == 'true' ? l10n.auditValueYes : l10n.auditValueNo,
    'species' => _speciesLabel(l10n, value),
    'closed_reason' => _closedReasonLabel(l10n, value),
    // Everything else is either a number, a free-text label somebody typed, or
    // a list already formatted by the server. All three are already the words
    // the reader wants.
    _ => value,
  };
}

String _speciesLabel(AppLocalizations l10n, String value) => switch (value) {
  'protected' => l10n.auditValueSpeciesProtected,
  'feral_pigeon' => l10n.auditValueSpeciesFeralPigeon,
  'unknown' => l10n.auditValueSpeciesUnknown,
  _ => value,
};

String _closedReasonLabel(AppLocalizations l10n, String value) =>
    switch (value) {
      'netted' => l10n.closedReasonNetted,
      'permission_withdrawn' => l10n.closedReasonPermissionWithdrawn,
      'building_gone' => l10n.closedReasonBuildingGone,
      'no_pigeons' => l10n.closedReasonNoPigeons,
      _ => value,
    };

/// The icon for what an entry is ABOUT — the second, non-colour signal, drawn
/// from the same vocabulary the rest of the app uses for these things.
IconData auditTargetIcon(String? targetType) => switch (targetType) {
  'spot' => Icons.home_work_outlined,
  'nest' => Icons.egg_outlined,
  'user' => Icons.person_outline,
  'org' => Icons.tune_outlined,
  _ => Icons.history,
};
