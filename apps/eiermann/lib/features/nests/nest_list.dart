import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/nests/nest_labels.dart';
import 'package:eiermann/features/nests/nest_sheet.dart';
import 'package:eiermann/features/nests/nests_providers.dart';
import 'package:eiermann/features/rhythm/due_explanation.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// The nests of one Bereich as LINES — what the photo cannot say.
///
/// The pins answer "where"; this answers "what is in it and how long has it
/// been like that", which is what decides whether somebody drives out there.
/// The concept puts both on the dossier's first screen for that reason: you
/// orient yourself on the picture, then read the list.
///
/// Urgent first, in the server's order. Nothing is re-sorted here: the rank is
/// a column of the view, and a list that re-ordered on the device would
/// disagree with the one the coordination is looking at.
class NestList extends StatelessWidget {
  const NestList({required this.nests, required this.areaId, super.key});

  final List<NestState> nests;
  final String areaId;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (nests.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: ZugvogelSpacing.sm),
            child: Text(
              l10n.nestsEmptyInArea,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          for (final nest in nests) NestLine(nest: nest, areaId: areaId),
        // The way in that does NOT need a photo — and the only way to record a
        // nest whose position nobody can point at yet. Without it a Bereich
        // with no photo is a dead end: the list says "tap the photo" beside a
        // box that says "no photo".
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => showNestSheet(
              context,
              areaId: areaId,
              suggestedLabel: suggestNestLabel(
                nests.map((nest) => nest.label),
              ),
            ),
            icon: const Icon(Icons.add),
            label: Text(l10n.nestsAddAction),
          ),
        ),
      ],
    );
  }
}

/// One nest: its label and where to look, what is in it, and how old that is.
class NestLine extends ConsumerWidget {
  const NestLine({required this.nest, required this.areaId, super.key});

  final NestState nest;
  final String areaId;

  /// The nest's own photo on the line, small.
  ///
  /// It answers what the Bereich photo cannot: two ledges that look identical
  /// from across the attic are told apart up close. Absent when there is none —
  /// a placeholder box on every line would be noise on exactly the screen that
  /// has to be readable at a glance.
  static const double _thumb = 40;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colour = nestSpeciesColor(context, nest.species);

    // A protected nest says what NOT to do, in place of a clutch reading: there
    // is no egg work to report on it, and the words are the whole point.
    final content = nest.isProtected
        ? [
            ?nest.speciesLabel,
            l10n.nestProtectedDoNotTouch,
          ].join(' — ')
        : nestContent(l10n, nest);

    final age = nest.ageInDays(DateTime.now());
    final repo = ref.watch(nestStateRepositoryProvider).value;
    final photo = nest.photo;
    // The date and the sentence that explains it, on one line under the
    // clutch. The sentence is built in the CLIENT from `empty_streak` and
    // `interval_days` — the server does not know which language the reader
    // speaks — and it is what turns a date people override into a decision
    // they can argue with.
    final due = nest.nextDueAt;
    final why = nestDueExplanation(l10n, nest);
    final rhythm = [
      if (due != null)
        l10n.spotDueOn(formatLocalDate(MaterialLocalizations.of(context), due)),
      ?why,
    ].join(' · ');

    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      // Colour AND shape, always: a red line says nothing to a colour-blind
      // volunteer, and colour as the only carrier of meaning fails WCAG 1.4.1.
      leading: Icon(nestSpeciesIcon(nest.species), color: colour),
      title: Row(
        children: [
          Text(nest.label, style: theme.textTheme.titleSmall),
          if (nest.positionHint case final hint?) ...[
            const SizedBox(width: ZugvogelSpacing.sm),
            Expanded(
              child: Text(
                hint,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
      isThreeLine: rhythm.isNotEmpty,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            content,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: nest.isProtected ? context.zvColors.critical : null,
              fontWeight: nest.isProtected ? FontWeight.bold : null,
            ),
          ),
          if (rhythm.isNotEmpty)
            Text(
              rhythm,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
      // The age is the second number the decision turns on, so it sits at the
      // end of the line where the eye lands last — and says so in words rather
      // than as a bare number.
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (photo != null && repo != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: CachedFileImage(
                // The 100px generation: this is drawn 40 logical pixels wide,
                // and asking for the original would send a phone photo down a
                // stairwell connection once per line.
                url: repo.fileUrl(nest.id, photo, thumb: '100x100'),
                width: _thumb,
                height: _thumb,
              ),
            ),
            const SizedBox(width: ZugvogelSpacing.sm),
          ],
          Text(
            age == null ? l10n.nestNeverChecked : l10n.nestAgeDays(age),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      onTap: () => showNestSheet(
        context,
        areaId: areaId,
        // The sheet edits the NEST, and the view is a read of it. Rebuilt
        // from the row rather than fetched again: the fields the sheet writes
        // are all here, and a request per tap is what the view exists to avoid.
        nest: nest.asNest,
      ),
    );
  }
}

/// What is in the nest, in words: "1 Kunst · 1 echt", or "leer".
///
/// Dummies first, because that is the number somebody packs the car by — the
/// concept calls it the smallest feature with the highest everyday value.
String nestContent(AppLocalizations l10n, NestState nest) {
  if (nest.isEmpty) return l10n.nestContentEmpty;
  return [
    if (nest.dummyCount > 0) l10n.nestContentDummy(nest.dummyCount),
    if (nest.realCount > 0) l10n.nestContentReal(nest.realCount),
  ].join(' · ');
}

/// The nest behind a view row, for the sheet that edits it.
extension NestStateAsNest on NestState {
  /// Everything `nests` stores, taken off the row that was already read.
  ///
  /// The rhythm fields travel too, because the sheet passes them straight back
  /// out as `status`/`note` — and nothing here may be SENT: `NestsRepository`
  /// decides what a body carries, and it leaves the ladder alone.
  Nest get asNest => Nest(
    id: id,
    label: label,
    area: area,
    spot: spot,
    org: org,
    positionHint: positionHint,
    pinX: pinX,
    pinY: pinY,
    photo: photo,
    species: species,
    speciesLabel: speciesLabel,
    status: status,
    intervalDays: intervalDays,
    emptyStreak: emptyStreak,
    nextDueAt: nextDueAt,
    note: note,
    created: created,
    updated: updated,
  );
}
