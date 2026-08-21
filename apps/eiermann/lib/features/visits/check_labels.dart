import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Every visit wire value as a word, an icon and a colour — in one place, and
/// each answering for null too: a value this build has no name for must never
/// be drawn as the nearest one it knows.

String checkStateLabel(AppLocalizations l10n, CheckState? state) =>
    switch (state) {
      CheckState.swapped => l10n.checkStateSwapped,
      CheckState.partial => l10n.checkStatePartial,
      CheckState.empty => l10n.checkStateEmpty,
      CheckState.untouched => l10n.checkStateUntouched,
      CheckState.notReachable => l10n.checkStateNotReachable,
      CheckState.gone => l10n.checkStateGone,
      CheckState.protected => l10n.checkStateProtected,
      null => l10n.checkStateUnreadable,
    };

/// The icon for a check state — the non-colour signal, for the reason every
/// list in this app carries one: colour alone fails WCAG 1.4.1.
IconData checkStateIcon(CheckState? state) => switch (state) {
  CheckState.swapped => Icons.swap_horiz,
  CheckState.partial => Icons.hourglass_bottom,
  CheckState.empty => Icons.check_circle_outline,
  CheckState.untouched => Icons.pan_tool_outlined,
  CheckState.notReachable => Icons.block_outlined,
  CheckState.gone => Icons.close,
  CheckState.protected => Icons.warning_amber_outlined,
  null => Icons.help_outline,
};

/// The colour for a check state, from the theme's semantic roles.
///
/// Two states are loud and the rest are not. [CheckState.partial] is a WARNING
/// because it is unfinished work with a deadline measured in days — the second
/// named field problem — and [CheckState.protected] is CRITICAL because §44
/// BNatSchG is the one rule in this app that must stop somebody. A swap is
/// [ZugvogelSemantics.good]: it is the job, done.
Color checkStateColor(BuildContext context, CheckState? state) {
  final colors = context.zvColors;
  return switch (state) {
    CheckState.swapped => colors.good,
    CheckState.partial => colors.warning,
    CheckState.protected => colors.critical,
    CheckState.empty ||
    CheckState.untouched ||
    CheckState.notReachable ||
    CheckState.gone ||
    null => Theme.of(context).colorScheme.onSurfaceVariant,
  };
}

String skipReasonLabel(AppLocalizations l10n, SkipReason? reason) =>
    switch (reason) {
      SkipReason.nobodyThere => l10n.skipReasonNobodyThere,
      SkipReason.noKey => l10n.skipReasonNoKey,
      SkipReason.accessBlocked => l10n.skipReasonAccessBlocked,
      SkipReason.noTime => l10n.skipReasonNoTime,
      SkipReason.construction => l10n.skipReasonConstruction,
      SkipReason.other => l10n.skipReasonOther,
      null => l10n.skipReasonUnreadable,
    };

/// The word for what is in one egg slot.
String eggKindLabel(AppLocalizations l10n, EggKind? kind) => switch (kind) {
  EggKind.real => l10n.nestCheckAddReal,
  EggKind.dummy => l10n.nestCheckAddDummy,
  null => l10n.nestCheckSlotUnreadable,
};

/// The icon for an egg slot.
///
/// A real egg and a dummy are the same shape in the world, so the difference
/// has to be carried by fill: the real one is solid, the Attrappe outlined.
/// Both keep a label under them — this is the row somebody counts eggs off.
IconData eggKindIcon(EggKind? kind) => switch (kind) {
  EggKind.real => Icons.egg,
  EggKind.dummy => Icons.egg_outlined,
  null => Icons.help_outline,
};

/// The colour for an egg slot.
///
/// A real egg is the WARNING role, and that is the whole point of the row: a
/// real egg in a city-pigeon nest is the thing the programme exists to
/// replace, and it is what makes this nest due. A dummy is the calm state —
/// the method working.
Color eggKindColor(BuildContext context, EggKind? kind) {
  final colors = context.zvColors;
  return switch (kind) {
    EggKind.real => colors.warning,
    EggKind.dummy => colors.good,
    null => Theme.of(context).colorScheme.onSurfaceVariant,
  };
}
