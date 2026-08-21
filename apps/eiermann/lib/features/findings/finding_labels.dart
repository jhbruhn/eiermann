import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Every Fund wire value as a word, an icon and a colour — in one place, and
/// each answering for null too: a kind this build has no name for must never be
/// drawn as the nearest one it knows.

String findingKindLabel(AppLocalizations l10n, FindingKind? kind) =>
    switch (kind) {
      FindingKind.deadBird => l10n.findingKindDeadBird,
      FindingKind.chick => l10n.findingKindChick,
      FindingKind.otherSpecies => l10n.findingKindOtherSpecies,
      FindingKind.siteChange => l10n.findingKindSiteChange,
      null => l10n.findingKindUnknown,
    };

/// The icon for a Fund — the non-colour signal, for the reason every list in
/// this app carries one: colour alone fails WCAG 1.4.1.
IconData findingKindIcon(FindingKind? kind) => switch (kind) {
  FindingKind.deadBird => Icons.dangerous_outlined,
  FindingKind.chick => Icons.egg_alt_outlined,
  FindingKind.otherSpecies => Icons.pets_outlined,
  FindingKind.siteChange => Icons.construction_outlined,
  null => Icons.help_outline,
};

/// The colour of a Fund, from the theme's semantic roles.
///
/// Only one kind is loud, and it is not the dead bird. A dead pigeon is a
/// normal, sad observation in this work — colouring it critical would spend the
/// loudest signal on the most common entry, and a colour that fires on
/// everything stops being read. [FindingKind.siteChange] is the WARNING because
/// it is the one kind that changes what the programme can do at this building:
/// netting or spikes mean the method no longer reaches it, and the follow-up is
/// a decision somebody has to make.
Color findingKindColor(BuildContext context, FindingKind? kind) {
  final colors = context.zvColors;
  return switch (kind) {
    FindingKind.siteChange => colors.warning,
    FindingKind.deadBird ||
    FindingKind.chick ||
    FindingKind.otherSpecies ||
    null => Theme.of(context).colorScheme.onSurfaceVariant,
  };
}

/// One Fund as a line: what, how many, which species, on which nest.
///
/// Built here rather than in each screen because the dossier's chronology and
/// the visit flow's review list must not describe the same row differently —
/// somebody comparing the two would have to work out whether the difference
/// means anything.
String findingSummary(
  AppLocalizations l10n,
  FindingKind? kind, {
  required int count,
  String? speciesLabel,
  String? nestLabel,
}) => [
  // The count leads only when it is more than one: "1× tote Taube" reads like
  // a form field, "tote Taube" reads like a sentence.
  if (count > 1)
    l10n.findingCountPrefix(count, findingKindLabel(l10n, kind))
  else
    findingKindLabel(l10n, kind),
  ?speciesLabel,
  if (nestLabel case final label?) l10n.findingAtNest(label),
].join(' · ');
