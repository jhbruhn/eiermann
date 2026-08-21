import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Every nest wire value as a word, in one place — and each answers for null
/// too: a select value this build does not know reads as null, and rendering it
/// as the nearest known value would state something untrue about a nest.

String nestSpeciesLabel(AppLocalizations l10n, NestSpecies? species) =>
    switch (species) {
      NestSpecies.feralPigeon => l10n.nestSpeciesFeralPigeon,
      NestSpecies.protected => l10n.nestSpeciesProtected,
      NestSpecies.unknown => l10n.nestSpeciesUnknown,
      null => l10n.nestSpeciesUnreadable,
    };

/// The icon for a species — the non-colour signal, because a red pin says
/// nothing to a colour-blind volunteer and colour as the only carrier of
/// meaning fails WCAG 1.4.1.
IconData nestSpeciesIcon(NestSpecies? species) => switch (species) {
  NestSpecies.feralPigeon => Icons.egg_outlined,
  NestSpecies.protected => Icons.warning_amber_outlined,
  NestSpecies.unknown => Icons.help_outline,
  null => Icons.help_outline,
};

/// The colour for a species, from the theme's semantic roles.
///
/// `protected` is CRITICAL rather than a warning: interfering with the clutch
/// of a protected species is prohibited under §44 BNatSchG, and this app makes
/// clutch swapping faster and more routine — which is exactly why the one
/// state that must stop somebody gets the loudest role. `unknown` is a
/// warning: an open question, not a prohibition. A species this build cannot
/// name gets no colour of its own, so it cannot be mistaken for one of the
/// three.
Color nestSpeciesColor(BuildContext context, NestSpecies? species) {
  final colors = context.zvColors;
  return switch (species) {
    NestSpecies.protected => colors.critical,
    NestSpecies.unknown => colors.warning,
    NestSpecies.feralPigeon => colors.good,
    null => Theme.of(context).colorScheme.onSurfaceVariant,
  };
}

String nestStatusLabel(AppLocalizations l10n, NestStatus? status) =>
    switch (status) {
      NestStatus.active => l10n.nestStatusActive,
      NestStatus.gone => l10n.nestStatusGone,
      null => l10n.nestStatusUnreadable,
    };
