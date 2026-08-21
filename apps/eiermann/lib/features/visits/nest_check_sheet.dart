import 'package:eiermann/features/nests/nest_labels.dart';
import 'package:eiermann/features/visits/check_labels.dart';
import 'package:eiermann/features/visits/egg_slots.dart';
import 'package:eiermann/features/visits/visits_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Opens the check sheet for [nest] and returns what it recorded.
///
/// Null means the reader backed out or discarded the entry, and the two are the
/// same thing on purpose: a nest with no check is a legitimate outcome of a
/// visit — somebody did not get to it — and the flow records nothing for it
/// rather than inventing a state.
Future<NestCheckDraft?> showNestCheckSheet(
  BuildContext context, {
  required NestState nest,
  NestCheckDraft? existing,
}) {
  return showAppSheet<NestCheckDraft?>(
    context,
    builder: (_) => NestCheckSheet(nest: nest, existing: existing),
  );
}

/// What happened at ONE nest, as the volunteer standing in front of it sees it.
///
/// It writes nothing. `nest_checks` has no create rule at all — the only writer
/// is the transactional visit endpoint — so this sheet returns a
/// [NestCheckDraft] and the flow sends every draft together. That is what makes
/// a half-finished visit unrepresentable rather than merely unlikely.
///
/// The shape is a reading and then an action, in that order, because that is
/// the order it happens in: the slot row starts as the last known clutch, the
/// volunteer corrects it to what is actually in there, and only then says what
/// they did about it. Deriving the state from the row instead of asking for it
/// is deliberate — [CheckState.empty] is the one state that stretches the
/// rhythm ladder, and it must come from "nothing was in there" rather than from
/// a control somebody tapped by mistake.
class NestCheckSheet extends ConsumerStatefulWidget {
  const NestCheckSheet({required this.nest, this.existing, super.key});

  final NestState nest;

  /// A draft this visit already recorded for the nest, for the second visit to
  /// the sheet. Re-derived into slots so the row shows what was entered rather
  /// than the stored clutch again.
  final NestCheckDraft? existing;

  @override
  ConsumerState<NestCheckSheet> createState() => _NestCheckSheetState();
}

class _NestCheckSheetState extends ConsumerState<NestCheckSheet>
    with DiscardGuard, FormSheetState {
  late final _note = TextEditingController(text: widget.existing?.note ?? '');
  late final _speciesLabel = TextEditingController(
    text: widget.existing?.speciesLabel ?? widget.nest.speciesLabel ?? '',
  );

  /// The egg row. Null until the stored clutch has been read — the sheet cannot
  /// show a row it has not loaded, and showing an empty one would read as "the
  /// nest is empty", which is a state with consequences.
  List<EggSlot>? _slots;

  /// A special state the reader picked by hand, or null while the clutch row is
  /// what decides.
  CheckState? _special;

  bool get _isProtected => widget.nest.isProtected;

  @override
  void initState() {
    super.initState();
    // A protected nest never loads a clutch: there is no egg work to record on
    // it, and a row of slots would be an invitation to do exactly the thing the
    // sheet exists to refuse. The state list replaces it.
    if (_isProtected) {
      _slots = const [];
      _special = widget.existing?.state ?? CheckState.protected;
    } else {
      _special = _specialOf(widget.existing?.state);
    }
  }

  @override
  void dispose() {
    _note.dispose();
    _speciesLabel.dispose();
    super.dispose();
  }

  /// [state] if it is one a reader picks by hand, else null.
  static CheckState? _specialOf(CheckState? state) =>
      state != null && kSpecialCheckStates.contains(state) ? state : null;

  /// Seeds the row from the stored eggs, or from a draft this visit already
  /// holds.
  ///
  /// From the DRAFT where there is one, and that matters: coming back to a nest
  /// must show what was entered, not the stored clutch again. Re-deriving the
  /// slots from the numbers loses which individual egg was old — the ages are
  /// gone once a swap is recorded — and that is the honest loss: after a swap
  /// there is no old egg left to date.
  List<EggSlot> _seed(List<NestEgg> eggs) {
    final draft = widget.existing;
    if (draft != null) {
      return [
        for (var i = 0; i < draft.removedReal; i++)
          const EggSlot(found: EggKind.real, action: SlotAction.swapped),
        for (var i = 0; i < draft.realBefore - draft.removedReal; i++)
          const EggSlot(found: EggKind.real),
        for (var i = 0; i < draft.dummyBefore; i++)
          const EggSlot(found: EggKind.dummy),
      ];
    }
    return [for (final egg in eggs) EggSlot.stored(egg)];
  }

  NestCheckDraft get _draft => draftFromSlots(
    nestId: widget.nest.id,
    nestLabel: widget.nest.label,
    slots: _slots ?? const [],
    override: _special,
    note: trimToNull(_note),
    speciesLabel: trimToNull(_speciesLabel),
  );

  void _apply() {
    // The clutch row must have LOADED before a draft can be built from it.
    // Without this the sheet would hand back an empty row as a reading, and an
    // empty row means `empty` — the one state that stretches the rhythm ladder.
    // A failed read is therefore refused here rather than turned into a
    // statement about the nest.
    if (_slots == null) {
      setSaveError(context.zv.errorLoadFailed);
      return;
    }
    // No server call, so no runSave: the draft goes into the visit, which is
    // the only thing that talks to a server. The numbers cannot be incoherent
    // from this form — a row cannot remove an egg it does not hold — so
    // [NestCheckDraftMath.isCoherent] guards the flow, not this sheet.
    Navigator.of(context).pop(_draft);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final eggs = ref.watch(nestEggsProvider(widget.nest.id));
    // Seeded once, the moment the stored clutch lands. A plain assignment and
    // not `setState`: this build is the one that needs the value, and there is
    // nothing to notify. Every later build keeps what the reader edited.
    if (!_isProtected && _slots == null && eggs.hasValue) {
      _slots = _seed(eggs.requireValue);
    }

    return guardUnsavedChanges(
      child: SheetScaffold(
        title: l10n.nestCheckTitle(widget.nest.label),
        formKey: formKey,
        onFormChanged: markDirty,
        isBusy: isBusy,
        error: saveError,
        onSave: _apply,
        saveLabel: l10n.nestCheckApplyAction,
        trailing: [
          if (widget.existing != null)
            TextButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.delete_outline),
              label: Text(l10n.nestCheckDiscardAction),
            ),
        ],
        children: [
          if (widget.nest.positionHint case final hint?)
            Padding(
              padding: const EdgeInsets.only(bottom: ZugvogelSpacing.md),
              child: Text(
                hint,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (_isProtected)
            const _ProtectedExplanation()
          else
            // The clutch row waits for the stored eggs. An error here is not
            // fatal to the visit — the reader can still record a special state
            // — but it must not silently become an empty nest.
            AsyncValueView(
              value: eggs,
              onRetry: () => ref.invalidate(nestEggsProvider(widget.nest.id)),
              data: (rows) {
                return _ClutchSection(
                  slots: _slots ?? const [],
                  unreadable: rows.where((egg) => egg.kind == null).length,
                  enabled: _special == null,
                  onChanged: (slots) => setState(() {
                    _slots = slots;
                    markDirty();
                  }),
                );
              },
            ),
          const SizedBox(height: ZugvogelSpacing.lg),
          _SpecialStates(
            states: _isProtected ? kProtectedCheckStates : kSpecialCheckStates,
            value: _special,
            // On a protected nest one of these is always chosen: there is no
            // clutch reading to fall back on.
            allowNone: !_isProtected,
            onChanged: (state) => setState(() {
              _special = state;
              markDirty();
            }),
          ),
          if (_special == CheckState.protected) ...[
            const SizedBox(height: ZugvogelSpacing.md),
            AppTextField(
              controller: _speciesLabel,
              label: l10n.nestCheckSpeciesLabel,
              hintText: l10n.nestFieldSpeciesLabelHint,
              prefixIcon: Icons.pets_outlined,
              enabled: !isBusy,
            ),
          ],
          const SizedBox(height: ZugvogelSpacing.md),
          AppTextField(
            controller: _note,
            label: l10n.nestCheckNoteLabel,
            prefixIcon: Icons.notes_outlined,
            enabled: !isBusy,
            maxLines: 3,
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          _Outcome(draft: _draft),
        ],
      ),
    );
  }
}

/// The clutch: what is in the nest, and what the volunteer did about it.
class _ClutchSection extends StatelessWidget {
  const _ClutchSection({
    required this.slots,
    required this.unreadable,
    required this.enabled,
    required this.onChanged,
  });

  final List<EggSlot> slots;
  final int unreadable;

  /// False while a special state is chosen: the clutch is then irrelevant, and
  /// the endpoint zeroes every count. Dimmed rather than removed, so picking
  /// "nicht erreichbar" by accident does not look like the row was lost.
  final bool enabled;

  final ValueChanged<List<EggSlot>> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final hasReal = slots.any(
      (slot) => slot.countsAsReal && slot.action == SlotAction.keep,
    );

    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.nestCheckClutchTitle, style: theme.textTheme.titleSmall),
          const SizedBox(height: ZugvogelSpacing.xs),
          Text(
            l10n.nestCheckClutchHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          if (slots.isEmpty)
            Text(
              l10n.nestCheckAfterEmpty,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            )
          else
            Wrap(
              spacing: ZugvogelSpacing.sm,
              runSpacing: ZugvogelSpacing.sm,
              children: [
                for (final (index, slot) in slots.indexed)
                  _SlotTile(
                    slot: slot,
                    enabled: enabled,
                    onTap: () => onChanged([
                      for (final (i, s) in slots.indexed)
                        if (i == index) s.cycled() else s,
                    ]),
                    onRemove: () => onChanged([
                      for (final (i, s) in slots.indexed)
                        if (i != index) s,
                    ]),
                  ),
              ],
            ),
          if (unreadable > 0) ...[
            const SizedBox(height: ZugvogelSpacing.sm),
            Text(
              l10n.nestCheckUnreadableEggs(unreadable),
              style: theme.textTheme.bodySmall?.copyWith(
                color: context.zvColors.warning,
              ),
            ),
          ],
          const SizedBox(height: ZugvogelSpacing.sm),
          Wrap(
            spacing: ZugvogelSpacing.sm,
            children: [
              TextButton.icon(
                onPressed: enabled
                    ? () => onChanged([...slots, EggSlot.added(EggKind.real)])
                    : null,
                icon: Icon(eggKindIcon(EggKind.real)),
                label: Text(l10n.nestCheckAddReal),
              ),
              TextButton.icon(
                onPressed: enabled
                    ? () => onChanged([...slots, EggSlot.added(EggKind.dummy)])
                    : null,
                icon: Icon(eggKindIcon(EggKind.dummy)),
                label: Text(l10n.nestCheckAddDummy),
              ),
            ],
          ),
          if (hasReal) ...[
            const SizedBox(height: ZugvogelSpacing.sm),
            // The standard case in one tap. Everything else on this sheet is
            // for the exceptions.
            FilledButton.tonalIcon(
              onPressed: enabled
                  ? () => onChanged([
                      for (final slot in slots) slot.swappedIfReal(),
                    ])
                  : null,
              icon: const Icon(Icons.swap_horiz),
              label: Text(l10n.nestCheckSwapAllAction),
            ),
          ],
          const SizedBox(height: ZugvogelSpacing.xs),
          Text(
            l10n.nestCheckCycleHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// One egg slot: what it is, how old it is, and what happened to it.
class _SlotTile extends StatelessWidget {
  const _SlotTile({
    required this.slot,
    required this.enabled,
    required this.onTap,
    required this.onRemove,
  });

  final EggSlot slot;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final materialL10n = MaterialLocalizations.of(context);
    final colour = eggKindColor(context, slot.found);
    final since = slot.since;
    final age = since == null
        ? l10n.nestCheckSlotNew
        : l10n.nestAgeDays(_days(since));

    final action = switch (slot.action) {
      SlotAction.keep => l10n.nestCheckSlotKeep,
      SlotAction.swapped => l10n.nestCheckSlotSwapped,
      SlotAction.removed => l10n.nestCheckSlotRemoved,
    };

    return Tooltip(
      // The date the age was measured from, for the reader who wants the fact
      // rather than the arithmetic. Through formatLocalDate like every date in
      // this app: PocketBase stores UTC, and after 22:00 CET a raw render is a
      // day out.
      message: since == null
          ? l10n.nestCheckSlotNew
          : formatLocalDate(materialL10n, since),
      child: InkWell(
        onTap: enabled && slot.countsAsReal ? onTap : null,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 88,
          padding: const EdgeInsets.symmetric(
            vertical: ZugvogelSpacing.sm,
            horizontal: ZugvogelSpacing.xs,
          ),
          decoration: BoxDecoration(
            border: Border.all(color: colour),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(eggKindIcon(slot.found), color: colour),
                  IconButton(
                    // Not "delete": the volunteer is correcting the record,
                    // not throwing an egg away.
                    tooltip: l10n.nestCheckSlotRemoveTooltip,
                    icon: const Icon(Icons.close, size: 16),
                    visualDensity: VisualDensity.compact,
                    onPressed: enabled ? onRemove : null,
                  ),
                ],
              ),
              Text(
                eggKindLabel(l10n, slot.found),
                style: theme.textTheme.labelSmall,
                textAlign: TextAlign.center,
              ),
              Text(
                age,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              // The action is drawn in the resulting egg's colour, so the row
              // reads as the nest will be left — that is what somebody
              // double-checks before climbing down.
              Text(
                action,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: eggKindColor(context, slot.resulting),
                  fontWeight: slot.wasRemoved ? FontWeight.bold : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Whole LOCAL days since [since] — the same derivation every age in this app
  /// uses, and never a subtraction of raw timestamps.
  static int _days(DateTime since) {
    final now = DateTime.now();
    final from = since.toLocal();
    return DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(from.year, from.month, from.day)).inDays;
  }
}

/// The states a reader picks by hand.
class _SpecialStates extends StatelessWidget {
  const _SpecialStates({
    required this.states,
    required this.value,
    required this.allowNone,
    required this.onChanged,
  });

  final List<CheckState> states;
  final CheckState? value;

  /// Whether tapping the selected chip clears it and hands the decision back to
  /// the clutch row.
  final bool allowNone;

  final ValueChanged<CheckState?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.nestCheckSpecialTitle,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: ZugvogelSpacing.sm),
        Wrap(
          spacing: ZugvogelSpacing.sm,
          runSpacing: ZugvogelSpacing.sm,
          children: [
            for (final state in states)
              ChoiceChip(
                selected: value == state,
                avatar: Icon(
                  checkStateIcon(state),
                  size: 18,
                  color: checkStateColor(context, state),
                ),
                label: Text(checkStateLabel(l10n, state)),
                onSelected: (selected) => onChanged(
                  selected || !allowNone ? state : null,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Why there is no swap path on this nest.
///
/// The concept is explicit that the path is REPLACED and not disabled: a greyed
/// out button says "not for you", and what has to be said is "not at all, and
/// here is why". §44 BNatSchG is the one rule in this app that must stop
/// somebody, and every egg mutation on such a nest is refused server-side on
/// every path — so the sentence is also the honest description of what the app
/// would do.
class _ProtectedExplanation extends StatelessWidget {
  const _ProtectedExplanation();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(ZugvogelSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              nestSpeciesIcon(NestSpecies.protected),
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: ZugvogelSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.nestCheckProtectedTitle,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                  const SizedBox(height: ZugvogelSpacing.xs),
                  Text(
                    l10n.nestCheckProtectedExplain,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The nest as this check will leave it, plus the Halbgelege warning.
///
/// Shown before the reader confirms, because it is the one thing they can still
/// correct while standing there — and because the Halbgelege is derived rather
/// than chosen, so nothing else on the sheet announces it.
class _Outcome extends StatelessWidget {
  const _Outcome({required this.draft});

  final NestCheckDraft draft;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = draft.effectiveState;

    // Dummies first, for the reason the nest list puts them first: it is the
    // number somebody packs the car by next time.
    final content = [
      if (draft.dummyAfter > 0) l10n.nestContentDummy(draft.dummyAfter),
      if (draft.realAfter > 0) l10n.nestContentReal(draft.realAfter),
    ].join(' · ');
    final after = !draft.touchesEggs
        ? ''
        : content.isEmpty
        ? l10n.nestCheckAfterEmpty
        : content;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              checkStateIcon(state),
              size: 18,
              color: checkStateColor(context, state),
            ),
            const SizedBox(width: ZugvogelSpacing.sm),
            Expanded(
              child: Text(
                '${l10n.nestCheckAfterTitle}: '
                '${checkStateLabel(l10n, state)}'
                '${after.isEmpty ? '' : ' · $after'}',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
        if (draft.isHalfClutch) ...[
          const SizedBox(height: ZugvogelSpacing.sm),
          Text(
            l10n.nestCheckHalfClutchWarning,
            style: theme.textTheme.bodySmall?.copyWith(
              color: context.zvColors.warning,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ],
    );
  }
}
