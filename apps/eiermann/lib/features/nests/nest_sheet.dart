import 'package:eiermann/core/auth/roles.dart';
import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/nests/nest_labels.dart';
import 'package:eiermann/features/nests/nests_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/ui/form_sheet.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Opens the sheet that adds a nest to [areaId], or edits [nest].
///
/// [pin] is where the volunteer tapped on the photo. Passing it here rather
/// than writing it first is what makes a placement one action: a nest row
/// created before the sheet is confirmed would leave an unnamed nest behind if
/// somebody backs out.
Future<void> showNestSheet(
  BuildContext context, {
  required String areaId,
  Nest? nest,
  ({double x, double y})? pin,
  String? suggestedLabel,
}) {
  return showAppSheet<void>(
    context,
    builder: (_) => NestSheet(
      areaId: areaId,
      nest: nest,
      pin: pin,
      suggestedLabel: suggestedLabel,
    ),
  );
}

/// Add or edit a nest: what it is called, where to look, and what is in it.
///
/// The species control is the load-bearing part. It is not a label but a safety
/// field: city pigeons are feral domestic animals, while the jackdaws, wood
/// pigeons and kestrels sitting in the same attics are protected under §44
/// BNatSchG. The way INTO `protected` is open to everybody — a volunteer
/// standing in front of a jackdaw must be able to stop the process immediately
/// — and the way out belongs to the coordination, because it re-enables egg
/// removal on that nest.
class NestSheet extends ConsumerStatefulWidget {
  const NestSheet({
    required this.areaId,
    this.nest,
    this.pin,
    this.suggestedLabel,
    super.key,
  });

  /// The Bereich the nest belongs to. Frozen on the edit path: re-parenting
  /// would carry the nest's whole check history to another building.
  final String areaId;

  final Nest? nest;

  /// Where on the photo this nest sits, when the sheet was opened by a tap.
  final ({double x, double y})? pin;

  final String? suggestedLabel;

  @override
  ConsumerState<NestSheet> createState() => _NestSheetState();
}

class _NestSheetState extends ConsumerState<NestSheet>
    with DiscardGuard, FormSheetState {
  late final _label = TextEditingController(
    text: widget.nest?.label ?? widget.suggestedLabel ?? '',
  );
  late final _hint = TextEditingController(
    text: widget.nest?.positionHint ?? '',
  );
  late final _speciesLabel = TextEditingController(
    text: widget.nest?.speciesLabel ?? '',
  );

  /// Unknown by default, and that is deliberate: the app does not identify
  /// species, so an undetermined nest stays an open question until a person
  /// decides. Defaulting to "city pigeon" would be the app making that call.
  late NestSpecies _species = widget.nest?.species ?? NestSpecies.unknown;

  bool get _isEdit => widget.nest != null;

  /// Whether this reader may move the nest OUT of `protected`.
  ///
  /// Read from the role rather than left to the server so a member never taps
  /// an option that comes back refused — the hook enforces the same rule, on
  /// purpose, and the two checks exist in both places.
  bool get _mayUnprotect =>
      ref.watch(currentUserProvider).value?.role?.canUnprotect ?? false;

  bool get _lockedProtected =>
      widget.nest?.species == NestSpecies.protected && !_mayUnprotect;

  @override
  void dispose() {
    _label.dispose();
    _hint.dispose();
    _speciesLabel.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(formKey.currentState?.validate() ?? false)) return;
    final navigator = Navigator.of(context);
    final existing = widget.nest;

    final ok = await runSave(() async {
      final repo = await ref.read(nestsRepositoryProvider.future);
      final body = NestsRepository.body(
        label: _label.text.trim(),
        species: _species,
        // A new nest is there; `gone` is something a later visit records, and
        // this form is not where a nest disappears.
        status: existing?.status ?? NestStatus.active,
        positionHint: trimToNull(_hint),
        speciesLabel: trimToNull(_speciesLabel),
        note: existing?.note,
        // The pin travels with the create so a placement is ONE write. On an
        // edit it is left alone: the drag on the photo owns it, and sending a
        // stale pair back would undo a move somebody made in between.
        pinX: existing == null ? widget.pin?.x : null,
        pinY: existing == null ? widget.pin?.y : null,
        // Create only: the collection freezes the Bereich and pins the org.
        // `spot` is never sent at all — a hook derives it from the Bereich.
        area: existing == null ? widget.areaId : null,
        org: existing == null ? (await requireUserOrg()).$2 : null,
      );
      if (existing == null) {
        await repo.create(body);
      } else {
        await repo.update(existing.id, body);
      }
      ref.invalidate(nestsForAreaProvider(widget.areaId));
    });
    if (ok && mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final strings = EiermannStrings(l10n);

    return guardUnsavedChanges(
      child: SheetScaffold(
        title: _isEdit ? l10n.nestSheetTitleEdit : l10n.nestSheetTitleNew,
        formKey: formKey,
        onFormChanged: markDirty,
        isBusy: isBusy,
        error: saveError,
        onSave: _save,
        children: [
          AppTextField(
            controller: _label,
            label: l10n.nestFieldLabel,
            hintText: l10n.nestFieldLabelHint,
            prefixIcon: Icons.tag,
            enabled: !isBusy,
            autofocus: !_isEdit,
            textInputAction: TextInputAction.next,
            validator: Validators.required(strings),
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          AppTextField(
            controller: _hint,
            label: l10n.nestFieldPositionHint,
            // What a pin cannot say: a photo shows where to look, this says
            // what to look at.
            hintText: l10n.nestFieldPositionHintHint,
            prefixIcon: Icons.push_pin_outlined,
            enabled: !isBusy,
          ),
          const SizedBox(height: ZugvogelSpacing.lg),
          Text(
            l10n.nestFieldSpecies,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: ZugvogelSpacing.sm),
          _SpeciesChoice(
            value: _species,
            enabled: !isBusy,
            lockedProtected: _lockedProtected,
            onChanged: (species) => setState(() {
              _species = species;
              markDirty();
            }),
          ),
          if (_lockedProtected) ...[
            const SizedBox(height: ZugvogelSpacing.sm),
            Text(
              // Says WHO can, not just that this reader cannot: a dead end
              // without an addressee is how a volunteer stops reporting things.
              l10n.nestProtectedLockedHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.zvColors.critical,
              ),
            ),
          ],
          if (_species != NestSpecies.feralPigeon) ...[
            const SizedBox(height: ZugvogelSpacing.md),
            AppTextField(
              controller: _speciesLabel,
              label: l10n.nestFieldSpeciesLabel,
              // Free text on purpose: a curated list goes stale, holding dead
              // entries and missing the one the volunteer is looking at.
              hintText: l10n.nestFieldSpeciesLabelHint,
              prefixIcon: Icons.pets_outlined,
              enabled: !isBusy,
            ),
          ],
        ],
      ),
    );
  }
}

/// The three species states as one row of choices.
///
/// Not a dropdown: this is the field somebody reaches for while looking at a
/// bird they were not expecting, and every option has to be visible without a
/// tap first. `protected` keeps its colour and its icon in the closed state
/// too, because that is the one that has to be recognisable at a glance.
class _SpeciesChoice extends StatelessWidget {
  const _SpeciesChoice({
    required this.value,
    required this.enabled,
    required this.lockedProtected,
    required this.onChanged,
  });

  final NestSpecies value;
  final bool enabled;

  /// The nest is already protected and this reader may not take that back.
  final bool lockedProtected;

  final ValueChanged<NestSpecies> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Wrap(
      spacing: ZugvogelSpacing.sm,
      runSpacing: ZugvogelSpacing.sm,
      children: [
        for (final species in NestSpecies.values)
          ChoiceChip(
            selected: value == species,
            avatar: Icon(
              nestSpeciesIcon(species),
              size: 18,
              color: nestSpeciesColor(context, species),
            ),
            label: Text(nestSpeciesLabel(l10n, species)),
            // Marking protected is never gated. Leaving it is, and then every
            // other option is what gets disabled — not the protected one, which
            // stays selectable so the state can be re-confirmed.
            onSelected:
                !enabled ||
                    (lockedProtected && species != NestSpecies.protected)
                ? null
                : (_) => onChanged(species),
          ),
      ],
    );
  }
}
