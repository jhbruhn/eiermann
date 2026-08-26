import 'package:eiermann/features/spots/spot_labels.dart';
import 'package:eiermann/features/team/team_labels.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';

/// The client half of the audit registry: every wire value, as a word.
///
/// **This file is a contract, and the vocabulary guard is what enforces it.**
/// That guard parses `ACTIONS` and the field tables out of
/// `app_audit_vocabulary.js` and fails on any entry that would render as its
/// raw column name — in EITHER language. A log row reading
/// "base_interval_days: 7 → 10" is a row written for whoever wrote the schema
/// rather than for whoever has to read it.
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
/// the one the guard test turns into a red build. It is also what lets an older
/// client render a newer server's action instead of showing a gap.
String auditActionLabel(AppLocalizations l10n, String action) =>
    switch (action) {
      'spot.created' => l10n.auditActionSpotCreated,
      'spot.updated' => l10n.auditActionSpotUpdated,
      'spot.deleted' => l10n.auditActionSpotDeleted,
      'spot.phase_changed' => l10n.auditActionSpotPhaseChanged,
      'spot.auto_resumed' => l10n.auditActionSpotAutoResumed,
      'contact.created' => l10n.auditActionContactCreated,
      'contact.updated' => l10n.auditActionContactUpdated,
      'contact.deleted' => l10n.auditActionContactDeleted,
      'area.created' => l10n.auditActionAreaCreated,
      'area.updated' => l10n.auditActionAreaUpdated,
      'area.deleted' => l10n.auditActionAreaDeleted,
      'nest.created' => l10n.auditActionNestCreated,
      'nest.updated' => l10n.auditActionNestUpdated,
      'nest.deleted' => l10n.auditActionNestDeleted,
      'nest.unprotected' => l10n.auditActionNestUnprotected,
      'nest.protected' => l10n.auditActionNestProtected,
      'visit.recorded' => l10n.auditActionVisitRecorded,
      'visit.updated' => l10n.auditActionVisitUpdated,
      'visit.deleted' => l10n.auditActionVisitDeleted,
      'visit_photo.added' => l10n.auditActionVisitPhotoAdded,
      'visit_photo.deleted' => l10n.auditActionVisitPhotoDeleted,
      'check.created' => l10n.auditActionCheckCreated,
      'check.updated' => l10n.auditActionCheckUpdated,
      'check.deleted' => l10n.auditActionCheckDeleted,
      'egg.created' => l10n.auditActionEggCreated,
      'egg.updated' => l10n.auditActionEggUpdated,
      'egg.deleted' => l10n.auditActionEggDeleted,
      'finding.created' => l10n.auditActionFindingCreated,
      'finding.updated' => l10n.auditActionFindingUpdated,
      'finding.deleted' => l10n.auditActionFindingDeleted,
      'follow_up.created' => l10n.auditActionFollowUpCreated,
      'follow_up.updated' => l10n.auditActionFollowUpUpdated,
      'follow_up.resolved' => l10n.auditActionFollowUpResolved,
      'follow_up.deleted' => l10n.auditActionFollowUpDeleted,
      'tour.created' => l10n.auditActionTourCreated,
      'tour.updated' => l10n.auditActionTourUpdated,
      'tour.deleted' => l10n.auditActionTourDeleted,
      'tour_spot.added' => l10n.auditActionTourSpotAdded,
      'tour_spot.updated' => l10n.auditActionTourSpotUpdated,
      'tour_spot.removed' => l10n.auditActionTourSpotRemoved,
      'tour_run.started' => l10n.auditActionTourRunStarted,
      'tour_run.updated' => l10n.auditActionTourRunUpdated,
      'tour_run.finished' => l10n.auditActionTourRunFinished,
      'tour_run.deleted' => l10n.auditActionTourRunDeleted,
      'user.invited' => l10n.auditActionUserInvited,
      'user.updated' => l10n.auditActionUserUpdated,
      'user.role_changed' => l10n.auditActionUserRoleChanged,
      'user.activated' => l10n.auditActionUserActivated,
      'user.deactivated' => l10n.auditActionUserDeactivated,
      'user.provisioned' => l10n.auditActionUserProvisioned,
      'auth.login' => l10n.auditActionAuthLogin,
      'auth.login_failed' => l10n.auditActionAuthLoginFailed,
      'auth.oauth2_login' => l10n.auditActionAuthOauth2Login,
      'auth.password_changed' => l10n.auditActionAuthPasswordChanged,
      'auth.password_reset' => l10n.auditActionAuthPasswordReset,
      'rhythm.changed' => l10n.auditActionRhythmChanged,
      'report.exported' => l10n.auditActionReportExported,
      _ => action,
    };

/// The column that changed, as a word: `base_interval_days` → "Grundfrist".
String auditFieldLabel(AppLocalizations l10n, String field) => switch (field) {
  'name' => l10n.auditFieldName,
  'street' => l10n.auditFieldStreet,
  'postal_code' => l10n.auditFieldPostalCode,
  'city' => l10n.auditFieldCity,
  'phase' => l10n.auditFieldPhase,
  'prospect_stage' => l10n.auditFieldProspectStage,
  'closed_reason' => l10n.auditFieldClosedReason,
  'paused_until' => l10n.auditFieldPausedUntil,
  'role' => l10n.auditFieldRole,
  'is_primary' => l10n.auditFieldIsPrimary,
  'sort_index' => l10n.auditFieldSortIndex,
  'label' => l10n.auditFieldLabel,
  'species' => l10n.auditFieldSpecies,
  'species_label' => l10n.auditFieldSpeciesLabel,
  'status' => l10n.auditFieldStatus,
  'interval_days' => l10n.auditFieldIntervalDays,
  'area' => l10n.auditFieldArea,
  'spot' => l10n.auditFieldSpot,
  'nest' => l10n.auditFieldNest,
  'visit' => l10n.auditFieldVisit,
  'visited_at' => l10n.auditFieldVisitedAt,
  'outcome' => l10n.auditFieldOutcome,
  'skip_reason' => l10n.auditFieldSkipReason,
  'author' => l10n.auditFieldAuthor,
  'author_name' => l10n.auditFieldAuthorName,
  'state' => l10n.auditFieldState,
  'real_before' => l10n.auditFieldRealBefore,
  'dummy_before' => l10n.auditFieldDummyBefore,
  'real_after' => l10n.auditFieldRealAfter,
  'dummy_after' => l10n.auditFieldDummyAfter,
  'removed_real' => l10n.auditFieldRemovedReal,
  'added_dummy' => l10n.auditFieldAddedDummy,
  'checked_at' => l10n.auditFieldCheckedAt,
  'slot_index' => l10n.auditFieldSlotIndex,
  'kind' => l10n.auditFieldKind,
  'since' => l10n.auditFieldSince,
  'count' => l10n.auditFieldCount,
  'found_at' => l10n.auditFieldFoundAt,
  'due_at' => l10n.auditFieldDueAt,
  'reason' => l10n.auditFieldReason,
  'resolved_at' => l10n.auditFieldResolvedAt,
  'is_active' => l10n.auditFieldIsActive,
  'tour' => l10n.auditFieldTour,
  'tour_name' => l10n.auditFieldTourName,
  'started_by_name' => l10n.auditFieldStartedByName,
  'started_at' => l10n.auditFieldStartedAt,
  'finished_at' => l10n.auditFieldFinishedAt,
  'email' => l10n.auditFieldEmail,
  'phone' => l10n.auditFieldPhone,
  'invited_by' => l10n.auditFieldInvitedBy,
  'password' => l10n.auditFieldPassword,
  'note' => l10n.auditFieldNote,
  'access_note' => l10n.auditFieldAccessNote,
  'pause_reason' => l10n.auditFieldPauseReason,
  'skip_note' => l10n.auditFieldSkipNote,
  'position_hint' => l10n.auditFieldPositionHint,
  'caption' => l10n.auditFieldCaption,
  'photo' => l10n.auditFieldPhoto,
  'facade_photo' => l10n.auditFieldFacadePhoto,
  'geo_confirmed' => l10n.auditFieldGeoConfirmed,
  'pins_need_review' => l10n.auditFieldPinsNeedReview,
  'base_interval_days' => l10n.rhythmBaseLabel,
  'empty_checks_per_step' => l10n.rhythmPerStepLabel,
  'interval_steps' => l10n.rhythmLadderLabel,
  'half_clutch_return_days' => l10n.rhythmHalfClutchLabel,
  'pause_auto_resume' => l10n.rhythmAutoResumeLabel,

  // Keys that appear only in an action's `detail` payload, not as columns.
  'checks' => l10n.auditFieldChecks,
  'findings' => l10n.auditFieldFindings,
  'format' => l10n.auditFieldFormat,
  'period' => l10n.auditFieldPeriod,
  'method' => l10n.auditFieldMethod,
  'provider' => l10n.auditFieldProvider,
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
/// the caller says so with its own copy (see [AuditChange.hasNoPrevious]).
String auditValueLabel(AppLocalizations l10n, String field, String value) {
  if (value.isEmpty) return value;
  return switch (field) {
    'phase' => spotPhaseLabel(l10n, SpotPhase.fromWire(value)),
    'role' => userRoleLabel(l10n, UserRole.fromWire(value)),
    // A bool arrives as the string SQLite stored. Rendered as a word, because
    // "is_active: false → true" is a row that makes the reader do the mapping.
    'is_active' ||
    'pause_auto_resume' ||
    'is_primary' ||
    'geo_confirmed' ||
    'pins_need_review' =>
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

/// Who acted, when the actor was not a person.
///
/// `cron` is the one that matters: a Spot leaving a pause was decided by a
/// schedule, and a row that could only say "System" would leave the reader
/// guessing which of them did it.
String? auditActorKindLabel(AppLocalizations l10n, String? kind) =>
    switch (kind) {
      'cron' => l10n.auditActorKindCron,
      'system' => l10n.auditActorKindSystem,
      // `user` and `superuser` are named by their own actor_label; a kind
      // beside the name would be noise on every ordinary row.
      _ => null,
    };

/// The icon for what an entry is ABOUT — the second, non-colour signal, drawn
/// from the same vocabulary the rest of the app uses for these things.
IconData auditSubjectIcon(String? subjectCollection) =>
    switch (subjectCollection) {
      'spots' => Icons.home_work_outlined,
      'spot_contacts' => Icons.contact_phone_outlined,
      'areas' => Icons.photo_outlined,
      'nests' => Icons.egg_outlined,
      'visits' || 'visit_photos' => Icons.checklist_outlined,
      'nest_checks' || 'nest_eggs' => Icons.egg_alt_outlined,
      'findings' || 'follow_ups' => Icons.report_outlined,
      'tours' || 'tour_spots' || 'tour_runs' => Icons.route_outlined,
      'users' => Icons.person_outline,
      'organisations' => Icons.tune_outlined,
      _ => Icons.history,
    };
