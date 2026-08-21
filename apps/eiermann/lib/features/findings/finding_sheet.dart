import 'package:eiermann/features/findings/finding_labels.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Opens the Fund sheet and returns what it recorded.
///
/// Null means the reader backed out or discarded the entry — the same two
/// meanings `showNestCheckSheet` gives it, and for the same reason: a finding
/// nobody confirmed must leave no trace, and "nothing found" is the normal
/// outcome of a visit rather than a gap in the record.
Future<FindingDraft?> showFindingSheet(
  BuildContext context, {
  required List<NestState> nests,
  FindingDraft? existing,
}) {
  return showAppSheet<FindingDraft?>(
    context,
    builder: (_) => FindingSheet(nests: nests, existing: existing),
  );
}

/// One Fund, as the person who is looking at it sees it.
///
/// Writes nothing: `findings` has no create rule, and the only writer is the
/// transactional visit endpoint. So this hands back a [FindingDraft] and the
/// flow sends every one of them with the checks, in one body under one
/// Idempotency-Key — a visit whose findings went missing on a second request
/// would be a record that quietly under-reports.
///
/// The kind has **no default**, and that is the one piece of friction the sheet
/// keeps. Starting on "Toter Vogel" would mean a stray tap on the save button
/// records a dead bird, and a finding is a fact about a building that ends up
/// in a report to an authority.
class FindingSheet extends ConsumerStatefulWidget {
  const FindingSheet({required this.nests, this.existing, super.key});

  /// The nests of this Spot, already loaded by the flow.
  ///
  /// Passed in rather than read here: the visit flow has them on screen, and a
  /// sheet that fetched its own copy would show a different list from the one
  /// behind it whenever the two reads disagreed.
  final List<NestState> nests;

  /// A finding this visit already recorded, for the second visit to the sheet.
  final FindingDraft? existing;

  @override
  ConsumerState<FindingSheet> createState() => _FindingSheetState();
}

class _FindingSheetState extends ConsumerState<FindingSheet>
    with DiscardGuard, FormSheetState {
  late final _species = TextEditingController(
    text: widget.existing?.speciesLabel ?? '',
  );
  late final _note = TextEditingController(text: widget.existing?.note ?? '');

  late FindingKind? _kind = widget.existing?.kind;
  late int _count = widget.existing?.count ?? 1;
  late String? _nest = widget.existing?.nest;

  /// Whether the save was pressed with no kind chosen.
  ///
  /// Shown next to the chips rather than in the sheet's error slot: what is
  /// missing is the answer to the question right above it, and the reader
  /// should not have to look to the bottom of the sheet to find that out.
  bool _kindMissing = false;

  /// The most a stepper offers. Not a limit on reality — a loft with thirty
  /// dead birds in it is a phone call, not a form — but the point past which
  /// tapping is the wrong control, and the note is where that belongs.
  static const _maxCount = 20;

  @override
  void dispose() {
    _species.dispose();
    _note.dispose();
    super.dispose();
  }

  /// Whether a species name is a question worth asking for [_kind].
  ///
  /// Not for a structural change: netting has no species, and an empty field
  /// under it invites somebody to type the building material. The three living
  /// or dead-bird kinds all do — including [FindingKind.deadBird], because a
  /// dead jackdaw is exactly the entry the next reader needs named.
  bool get _wantsSpecies => _kind != null && _kind != FindingKind.siteChange;

  FindingDraft? get _draft {
    final kind = _kind;
    if (kind == null) return null;
    return FindingDraft(
      kind: kind,
      count: _count,
      // Dropped along with the field: a species typed before switching to
      // "bauliche Veränderung" would otherwise ride along invisibly.
      speciesLabel: _wantsSpecies ? trimToNull(_species) : null,
      note: trimToNull(_note),
      nest: _nest,
      // Resolved here, while the list is in hand. An id with no label next to
      // it is a bug in this app, and once the sheet closes there is nothing to
      // look one up in until the visit has been written.
      nestLabel: _nest == null ? null : _labelOf(_nest!),
    );
  }

  /// The label of the nest with [id], or null.
  String? _labelOf(String id) {
    for (final nest in widget.nests) {
      if (nest.id == id) return nest.label;
    }
    return null;
  }

  void _apply() {
    final draft = _draft;
    if (draft == null) {
      setState(() => _kindMissing = true);
      return;
    }
    // No server call, so no runSave: the draft goes into the visit, which is
    // the only thing on this screen that talks to a server.
    Navigator.of(context).pop(draft);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return guardUnsavedChanges(
      child: SheetScaffold(
        title: widget.existing == null
            ? l10n.findingSheetTitleNew
            : l10n.findingSheetTitleEdit,
        formKey: formKey,
        onFormChanged: markDirty,
        isBusy: isBusy,
        error: saveError,
        onSave: _apply,
        saveLabel: l10n.findingApplyAction,
        trailing: [
          if (widget.existing != null)
            TextButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.delete_outline),
              label: Text(l10n.findingDiscardAction),
            ),
        ],
        children: [
          Text(l10n.findingKindQuestion, style: theme.textTheme.titleSmall),
          const SizedBox(height: ZugvogelSpacing.sm),
          Wrap(
            spacing: ZugvogelSpacing.sm,
            runSpacing: ZugvogelSpacing.sm,
            children: [
              for (final kind in FindingKind.values)
                ChoiceChip(
                  selected: _kind == kind,
                  avatar: Icon(
                    findingKindIcon(kind),
                    size: 18,
                    color: findingKindColor(context, kind),
                  ),
                  label: Text(findingKindLabel(l10n, kind)),
                  onSelected: (_) => setState(() {
                    _kind = kind;
                    // Choosing one clears the complaint, rather than leaving it
                    // standing under a form that is now complete.
                    _kindMissing = false;
                    markDirty();
                  }),
                ),
            ],
          ),
          if (_kindMissing) ...[
            const SizedBox(height: ZugvogelSpacing.xs),
            Text(
              l10n.findingKindMissing,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          if (_kind == FindingKind.siteChange) ...[
            const SizedBox(height: ZugvogelSpacing.md),
            const _SiteChangeHint(),
          ],
          const SizedBox(height: ZugvogelSpacing.lg),
          _CountStepper(
            count: _count,
            max: _maxCount,
            onChanged: (value) => setState(() {
              _count = value;
              markDirty();
            }),
          ),
          if (_wantsSpecies) ...[
            const SizedBox(height: ZugvogelSpacing.md),
            AppTextField(
              controller: _species,
              label: l10n.findingSpeciesLabel,
              prefixIcon: Icons.pets_outlined,
              enabled: !isBusy,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: ZugvogelSpacing.xs),
            Text(
              l10n.findingSpeciesHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: ZugvogelSpacing.md),
          _NestPicker(
            nests: widget.nests,
            value: _nest,
            enabled: !isBusy,
            onChanged: (id) => setState(() {
              _nest = id;
              markDirty();
            }),
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          AppTextField(
            controller: _note,
            label: l10n.findingNoteLabel,
            prefixIcon: Icons.notes_outlined,
            enabled: !isBusy,
            maxLines: 3,
          ),
        ],
      ),
    );
  }
}

/// Why a structural change does not close the Spot by itself.
class _SiteChangeHint extends StatelessWidget {
  const _SiteChangeHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(ZugvogelSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.info_outline,
              size: 20,
              color: context.zvColors.warning,
            ),
            const SizedBox(width: ZugvogelSpacing.sm),
            Expanded(
              child: Text(
                context.l10n.findingSiteChangeHint,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// How many, as a stepper.
///
/// A stepper and not a number keyboard: this is tapped in a stairwell, often
/// one-handed, and the numbers are small. A keyboard would also let somebody
/// leave the field mid-edit with "1" still showing and a "2" they meant.
class _CountStepper extends StatelessWidget {
  const _CountStepper({
    required this.count,
    required this.max,
    required this.onChanged,
  });

  final int count;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.findingCountLabel, style: theme.textTheme.titleSmall),
        const SizedBox(height: ZugvogelSpacing.xs),
        Row(
          children: [
            IconButton.outlined(
              // One is the floor, not zero: a Fund of nothing is not a Fund,
              // and the way to record nothing is to not record it.
              onPressed: count > 1 ? () => onChanged(count - 1) : null,
              icon: const Icon(Icons.remove),
              tooltip: l10n.findingCountFewer,
            ),
            SizedBox(
              width: 56,
              child: Text(
                '$count',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge,
              ),
            ),
            IconButton.outlined(
              onPressed: count < max ? () => onChanged(count + 1) : null,
              icon: const Icon(Icons.add),
              tooltip: l10n.findingCountMore,
            ),
            const SizedBox(width: ZugvogelSpacing.md),
            Expanded(
              child: Text(
                l10n.findingCountHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Which nest this is about, or the building.
///
/// The building is the DEFAULT and the first entry, because it is the honest
/// answer more often than not: a dead bird on the floor of a stairwell belongs
/// to no nest, and a picker that made somebody choose one would attach an
/// observation to a nest nobody looked at.
class _NestPicker extends StatelessWidget {
  const _NestPicker({
    required this.nests,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final List<NestState> nests;
  final String? value;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Nothing to choose between: a Spot with no nests still gets findings —
    // that is often what the first visit produces — and a dropdown with one
    // entry is a control that does nothing.
    if (nests.isEmpty) return const SizedBox.shrink();

    return DropdownButtonFormField<String?>(
      initialValue: value,
      decoration: InputDecoration(
        labelText: l10n.findingNestLabel,
        border: const OutlineInputBorder(),
        prefixIcon: const Icon(Icons.home_work_outlined),
      ),
      items: [
        DropdownMenuItem(child: Text(l10n.findingNestNone)),
        for (final nest in nests)
          DropdownMenuItem(value: nest.id, child: Text(nest.label)),
      ],
      onChanged: enabled ? onChanged : null,
    );
  }
}
