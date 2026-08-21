import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Every wire value the Spot screens show as a word, in one place.
///
/// Each label takes the nullable enum and answers something for null too: a
/// select value this build does not know reads as null (see `WireEnum`), and a
/// row that silently rendered it as the nearest known value would state
/// something untrue about a building.

String spotPhaseLabel(AppLocalizations l10n, SpotPhase? phase) =>
    switch (phase) {
      SpotPhase.prospect => l10n.spotPhaseProspect,
      SpotPhase.active => l10n.spotPhaseActive,
      SpotPhase.paused => l10n.spotPhasePaused,
      SpotPhase.closed => l10n.spotPhaseClosed,
      null => l10n.spotPhaseUnknown,
    };

String prospectStageLabel(AppLocalizations l10n, ProspectStage stage) =>
    switch (stage) {
      ProspectStage.untouched => l10n.prospectStageUntouched,
      ProspectStage.tenantSpoken => l10n.prospectStageTenantSpoken,
      ProspectStage.ownerSpoken => l10n.prospectStageOwnerSpoken,
      ProspectStage.permitted => l10n.prospectStagePermitted,
      ProspectStage.refused => l10n.prospectStageRefused,
    };

String closedReasonLabel(AppLocalizations l10n, ClosedReason reason) =>
    switch (reason) {
      ClosedReason.netted => l10n.closedReasonNetted,
      ClosedReason.permissionWithdrawn => l10n.closedReasonPermissionWithdrawn,
      ClosedReason.buildingGone => l10n.closedReasonBuildingGone,
      ClosedReason.noPigeons => l10n.closedReasonNoPigeons,
    };

String contactRoleLabel(AppLocalizations l10n, ContactRole? role) =>
    switch (role) {
      ContactRole.owner => l10n.contactRoleOwner,
      ContactRole.management => l10n.contactRoleManagement,
      ContactRole.caretaker => l10n.contactRoleCaretaker,
      ContactRole.tenant => l10n.contactRoleTenant,
      ContactRole.other => l10n.contactRoleOther,
      null => l10n.contactRoleUnknown,
    };

/// Why this Spot is where it is in the list — **in words**.
///
/// The list also colours the rank (see [spotUrgencyColor]), and this is the
/// half that carries the meaning. Colour alone fails WCAG 1.4.1, and a red row
/// tells a colour-blind carer nothing at all; the sentence has to be readable
/// with the colour removed, which is why nothing in the list renders the rank
/// as a bare dot or a coloured bar.
String spotUrgencyLabel(AppLocalizations l10n, SpotUrgency? level) =>
    switch (level) {
      SpotUrgency.overdue => l10n.spotUrgencyOverdue,
      SpotUrgency.dueToday => l10n.spotUrgencyDueToday,
      SpotUrgency.dueThisWeek => l10n.spotUrgencyDueThisWeek,
      SpotUrgency.inRhythm => l10n.spotUrgencyInRhythm,
      SpotUrgency.prospect => l10n.spotUrgencyProspect,
      SpotUrgency.paused => l10n.spotUrgencyPaused,
      SpotUrgency.closed => l10n.spotUrgencyClosed,
      null => l10n.spotUrgencyUnknown,
    };

/// The colour for an urgency rank, from the theme's semantic roles.
///
/// Never a literal: `critical`, `warning` and `good` follow brightness through
/// the theme extension, and hard-coding a hue here is what produces a red that
/// is unreadable in dark mode. The three quiet ranks — prospect, paused,
/// closed — deliberately get no colour of their own: they are not degrees of
/// urgency, and giving them one invites the reader to compare them with the due
/// ranks. Same for a rank this build cannot name.
Color spotUrgencyColor(BuildContext context, SpotUrgency? level) {
  final colors = context.zvColors;
  return switch (level) {
    SpotUrgency.overdue => colors.critical,
    SpotUrgency.dueToday || SpotUrgency.dueThisWeek => colors.warning,
    SpotUrgency.inRhythm => colors.good,
    _ => Theme.of(context).colorScheme.onSurfaceVariant,
  };
}

/// The icon beside the urgency words — a second, non-colour signal for the
/// ranks that call for action.
IconData spotUrgencyIcon(SpotUrgency? level) => switch (level) {
  SpotUrgency.overdue => Icons.priority_high,
  SpotUrgency.dueToday || SpotUrgency.dueThisWeek => Icons.schedule,
  SpotUrgency.inRhythm => Icons.check_circle_outline,
  SpotUrgency.prospect => Icons.forum_outlined,
  SpotUrgency.paused => Icons.pause_circle_outline,
  SpotUrgency.closed => Icons.block,
  null => Icons.help_outline,
};
