import 'package:eiermann/features/rhythm/due_countdown.dart';
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

/// The icon beside a phase — the second, non-colour signal, and the same
/// vocabulary the urgency ranks use so a reader learns one set of shapes.
IconData spotPhaseIcon(SpotPhase? phase) => switch (phase) {
  SpotPhase.prospect => Icons.forum_outlined,
  SpotPhase.active => Icons.check_circle_outline,
  SpotPhase.paused => Icons.pause_circle_outline,
  SpotPhase.closed => Icons.block,
  null => Icons.help_outline,
};

/// What the button for moving a Spot from [from] to [to] should say.
///
/// A verb, not a destination: "Aktivieren" reads as something to do, and
/// "Aktiv" reads as a state that is already the case. Three of them arrive at
/// the same phase and none of them can borrow the others' word — resuming a
/// pause, reopening a closing and activating an Erkundung are different acts
/// with different consequences, and the menu is where the difference has to be
/// legible.
String spotPhaseMoveLabel(
  AppLocalizations l10n,
  SpotPhase from,
  SpotPhase to,
) => switch ((from, to)) {
  (SpotPhase.paused, SpotPhase.active) => l10n.spotMoveResume,
  (SpotPhase.closed, SpotPhase.active) => l10n.spotMoveReopen,
  (_, SpotPhase.active) => l10n.spotMoveActivate,
  // paused → paused: not a transition, and the label says so. It exists so
  // correcting a pause's end date is not spelled as resume-then-pause-again.
  (SpotPhase.paused, SpotPhase.paused) => l10n.spotMoveEditPause,
  (_, SpotPhase.paused) => l10n.spotMovePause,
  (_, SpotPhase.closed) => l10n.spotMoveClose,
  // Unreachable through the transition graph — nothing leads back to an
  // Erkundung, because permission once obtained is not un-learned. Named
  // rather than thrown: an exhaustive switch that throws turns a graph the
  // server widened into a crash instead of a plain word.
  (_, SpotPhase.prospect) => l10n.spotPhaseProspect,
};

String prospectStageLabel(AppLocalizations l10n, ProspectStage stage) =>
    switch (stage) {
      ProspectStage.untouched => l10n.prospectStageUntouched,
      ProspectStage.tenantSpoken => l10n.prospectStageTenantSpoken,
      ProspectStage.ownerSpoken => l10n.prospectStageOwnerSpoken,
      ProspectStage.permitted => l10n.prospectStagePermitted,
      ProspectStage.refused => l10n.prospectStageRefused,
    };

/// The icon for one Erkundung stage.
///
/// Shape as well as words, for the same reason the urgency ranks carry one: the
/// funnel's groups are told apart at a glance, and a heading that differs only
/// in its text is one a reader has to stop and read.
IconData prospectStageIcon(ProspectStage stage) => switch (stage) {
  // Nobody asked yet.
  ProspectStage.untouched => Icons.help_outline,
  ProspectStage.tenantSpoken => Icons.people_outline,
  ProspectStage.ownerSpoken => Icons.apartment_outlined,
  ProspectStage.permitted => Icons.check_circle_outline,
  ProspectStage.refused => Icons.block_outlined,
};

/// What moves a Spot out of [stage] — one sentence per stage.
///
/// A group of buildings waiting on the same thing needs the same next step, so
/// it is said once per group rather than once per row. The wording is the whole
/// value of the funnel screen: "Eigentümer gesprochen" is a state, "auf die
/// Antwort warten und nachfassen" is what to do about it.
String prospectStageNextAction(AppLocalizations l10n, ProspectStage stage) =>
    switch (stage) {
      ProspectStage.untouched => l10n.prospectsNextUntouched,
      ProspectStage.tenantSpoken => l10n.prospectsNextTenantSpoken,
      ProspectStage.ownerSpoken => l10n.prospectsNextOwnerSpoken,
      ProspectStage.permitted => l10n.prospectsNextPermitted,
      ProspectStage.refused => l10n.prospectsNextRefused,
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
      SpotUrgency.dueSoon => l10n.spotUrgencyDueSoon,
      SpotUrgency.inRhythm => l10n.spotUrgencyInRhythm,
      SpotUrgency.needsSurvey => l10n.spotUrgencyNeedsSurvey,
      SpotUrgency.prospect => l10n.spotUrgencyProspect,
      SpotUrgency.paused => l10n.spotUrgencyPaused,
      SpotUrgency.closed => l10n.spotUrgencyClosed,
      null => l10n.spotUrgencyUnknown,
    };

/// The due line for ONE Spot — a day count, not a rank name.
///
/// [spotUrgencyLabel] still names the rank where it labels a GROUP: a filter
/// chip, a dashboard tile, a map cluster. A single row is different, because
/// the row already carries the date, and the rank next to it restated that date
/// worse than the date did — "Diese Woche fällig · fällig am 24.08." says
/// fällig twice and the first half was true of every Spot in the org
/// (eiermann-uga). So the row says how many days, and the date stays beside it
/// as the reference.
///
/// The three quiet ranks and anything undated keep their NAME, because for them
/// the absence of a date is the fact: a count of days to a paused Spot's next
/// visit would invent one. Same reasoning as the first two branches of
/// `nestDueExplanation`, which answers for the nests.
String spotDueLabel(
  AppLocalizations l10n,
  SpotUrgency? level,
  DateTime? dueAt, {
  DateTime? now,
}) {
  if (dueAt == null) return spotUrgencyLabel(l10n, level);
  return switch (level) {
    // `needsSurvey` joins the quiet ranks here even though it DOES carry a
    // date, and that is the whole reason it has a rung: the date is a
    // placeholder the server derived from the day the Spot was added, so
    // "fällig in 5 Tagen" would state a deadline nobody set. The three below it
    // keep their name because they have no date; this one keeps its name
    // because the date it has is not one to count down to.
    SpotUrgency.needsSurvey ||
    SpotUrgency.prospect ||
    SpotUrgency.paused ||
    SpotUrgency.closed ||
    // A rank this build has no name for gets the unknown label rather than a
    // confident day count: the server grew a rung, and guessing what it means
    // is worse than saying so.
    null => spotUrgencyLabel(l10n, level),
    _ => switch (dueInDays(dueAt, now: now)) {
      final days when days < 0 => l10n.spotDueOverdueDays(-days),
      0 => l10n.spotUrgencyDueToday,
      final days => l10n.spotDueInDays(days),
    },
  };
}

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
    SpotUrgency.dueToday || SpotUrgency.dueSoon => colors.warning,
    SpotUrgency.inRhythm => colors.good,
    // `needsSurvey` falls to the neutral colour with the three quiet ranks, and
    // it is the case the sentence above was written for: it is WORK, but it is
    // not a degree of urgency, so a warning hue would invite the reader to
    // weigh it against a nest falling due tomorrow. Its icon, its word and its
    // dashboard tile carry it instead. What it must never look like again is
    // `good` — green on a building nobody has been inside is the bug this rung
    // exists to fix (eiermann-m0r).
    _ => Theme.of(context).colorScheme.onSurfaceVariant,
  };
}

/// The icon beside the urgency words — a second, non-colour signal for the
/// ranks that call for action.
IconData spotUrgencyIcon(SpotUrgency? level) => switch (level) {
  SpotUrgency.overdue => Icons.priority_high,
  SpotUrgency.dueToday || SpotUrgency.dueSoon => Icons.schedule,
  SpotUrgency.inRhythm => Icons.check_circle_outline,
  // A search, not a clock: the shape has to say "go and look", because it is
  // the half of the signal that survives the colour being neutral.
  SpotUrgency.needsSurvey => Icons.travel_explore,
  SpotUrgency.prospect => Icons.forum_outlined,
  SpotUrgency.paused => Icons.pause_circle_outline,
  SpotUrgency.closed => Icons.block,
  null => Icons.help_outline,
};
