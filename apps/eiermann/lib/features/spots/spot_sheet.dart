import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/spots/spot_labels.dart';
import 'package:eiermann/features/spots/spots_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/ui/form_sheet.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Opens the create sheet, or the edit sheet for [spot]. Resolves to the id of
/// the Spot that was written, or null if the sheet was dismissed.
Future<String?> showSpotSheet(BuildContext context, {Spot? spot}) {
  return showAppSheet<String>(
    context,
    builder: (_) => SpotSheet(spot: spot),
  );
}

/// Create or edit a Spot: what it is called, where it is, how you get in.
///
/// The geocoding and the manual pin correction are deliberately NOT here yet
/// (eiermann-upa.3, upa.6) — the address is the identity and the coordinates
/// are for the map, so a Spot is worth recording before anybody has pinned it.
/// The phase transitions that need a reason (pausing, closing) are their own
/// flows for the same kind of reason: this sheet may set the phase, but a
/// closing without its mandatory reason is a state nobody can act on later, so
/// it does not offer one.
class SpotSheet extends ConsumerStatefulWidget {
  const SpotSheet({this.spot, super.key});

  /// The Spot being edited, or null to create one.
  final Spot? spot;

  @override
  ConsumerState<SpotSheet> createState() => _SpotSheetState();
}

class _SpotSheetState extends ConsumerState<SpotSheet>
    with DiscardGuard, FormSheetState {
  late final _name = TextEditingController(text: widget.spot?.name ?? '');
  late final _street = TextEditingController(text: widget.spot?.street ?? '');
  late final _postalCode = TextEditingController(
    text: widget.spot?.postalCode ?? '',
  );
  late final _city = TextEditingController(text: widget.spot?.city ?? '');
  late final _accessNote = TextEditingController(
    text: widget.spot?.accessNote ?? '',
  );
  late final _note = TextEditingController(text: widget.spot?.note ?? '');

  /// A new Spot starts as an Erkundung: somebody walked past a building and
  /// there is no permission yet, which is the honest default. An existing Spot
  /// whose stored phase this build cannot read stays null, and the form then
  /// insists on a choice rather than silently rewriting it.
  late SpotPhase? _phase = widget.spot == null
      ? SpotPhase.prospect
      : widget.spot!.phase;

  bool _phaseMissing = false;

  bool get _isEdit => widget.spot != null;

  @override
  void dispose() {
    _name.dispose();
    _street.dispose();
    _postalCode.dispose();
    _city.dispose();
    _accessNote.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final phase = _phase;
    if (_phaseMissing != (phase == null)) {
      setState(() => _phaseMissing = phase == null);
    }
    if (!(formKey.currentState?.validate() ?? false) || phase == null) return;
    final navigator = Navigator.of(context);
    final existing = widget.spot;

    String? writtenId;
    final ok = await runSave(() async {
      final repo = await ref.read(spotsRepositoryProvider.future);
      final body = SpotsRepository.body(
        name: _name.text.trim(),
        phase: phase,
        street: trimToNull(_street),
        postalCode: trimToNull(_postalCode),
        city: trimToNull(_city),
        accessNote: trimToNull(_accessNote),
        note: trimToNull(_note),
        // Only on create: the update rule refuses a body that carries org at
        // all, because it would be authorised against the stored one.
        org: existing == null ? (await requireUserOrg()).$2 : null,
      );
      final written = existing == null
          ? await repo.create(body)
          : await repo.update(existing.id, body);
      writtenId = written.id;

      ref.invalidate(spotFeedProvider);
      if (existing != null) ref.invalidate(spotProvider(existing.id));
    });
    if (ok && mounted) navigator.pop(writtenId);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final strings = EiermannStrings(l10n);

    return guardUnsavedChanges(
      child: SheetScaffold(
        title: _isEdit ? l10n.spotSheetTitleEdit : l10n.spotSheetTitleNew,
        formKey: formKey,
        onFormChanged: markDirty,
        isBusy: isBusy,
        error: saveError,
        onSave: _save,
        children: [
          AppTextField(
            controller: _name,
            label: l10n.spotFieldName,
            hintText: l10n.spotFieldNameHint,
            prefixIcon: Icons.home_work_outlined,
            enabled: !isBusy,
            autofocus: !_isEdit,
            textInputAction: TextInputAction.next,
            validator: Validators.required(strings),
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          AppTextField(
            controller: _street,
            label: l10n.spotFieldStreet,
            prefixIcon: Icons.signpost_outlined,
            enabled: !isBusy,
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The postcode is fixed-width and the town is not, so they share
              // a row rather than each taking a full line in a sheet somebody
              // fills in one-handed.
              SizedBox(
                width: 120,
                child: AppTextField(
                  controller: _postalCode,
                  label: l10n.spotFieldPostalCode,
                  enabled: !isBusy,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.next,
                ),
              ),
              const SizedBox(width: ZugvogelSpacing.md),
              Expanded(
                child: AppTextField(
                  controller: _city,
                  label: l10n.spotFieldCity,
                  enabled: !isBusy,
                  textInputAction: TextInputAction.next,
                ),
              ),
            ],
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          DropdownButtonFormField<SpotPhase>(
            initialValue: _phase,
            decoration: InputDecoration(
              labelText: l10n.spotPhaseLabel,
              prefixIcon: const Icon(Icons.flag_outlined),
              errorText: _phaseMissing ? l10n.fieldRequired : null,
            ),
            items: [
              for (final phase in SpotPhase.values)
                DropdownMenuItem(
                  value: phase,
                  child: Text(spotPhaseLabel(l10n, phase)),
                ),
            ],
            onChanged: isBusy
                ? null
                : (phase) => setState(() {
                    _phase = phase;
                    _phaseMissing = false;
                    markDirty();
                  }),
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          // Above the free-form note on purpose: this is the field a handover
          // actually turns on, and a form puts what matters first.
          AppTextField(
            controller: _accessNote,
            label: l10n.spotFieldAccessNote,
            hintText: l10n.spotFieldAccessNoteHint,
            prefixIcon: Icons.key_outlined,
            enabled: !isBusy,
            maxLines: 3,
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          AppTextField(
            controller: _note,
            label: l10n.spotFieldNote,
            prefixIcon: Icons.notes_outlined,
            enabled: !isBusy,
            maxLines: 3,
          ),
        ],
      ),
    );
  }
}
