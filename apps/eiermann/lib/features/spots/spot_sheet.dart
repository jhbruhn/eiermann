import 'dart:async';

import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/spots/spot_labels.dart';
import 'package:eiermann/features/spots/spot_pin_picker.dart';
import 'package:eiermann/features/spots/spots_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/ui/form_sheet.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_core/zugvogel_core.dart';
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
/// The pin is offered but never REQUIRED. The address is the identity and the
/// coordinates are for the map, so a Spot somebody walked past is worth
/// recording before anybody has pinned it — and the form says out loud what a
/// missing pin costs instead of refusing the save.
///
/// Two ways to a pin, and the difference between them is stored. Looking it up
/// from the address leaves `geo_confirmed` false, because a geocoder can land
/// on the wrong side of a courtyard; placing it on the map by hand sets the
/// flag. The dossier and the map both show which one it was.
///
/// The phase transitions that need a reason (pausing, closing) are their own
/// flow: this sheet may set the phase, but a closing without its mandatory
/// reason is a state nobody can act on later, so it does not offer one.
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

  late GeoPoint? _geo = widget.spot?.geo;

  /// Whether a person put THIS pin where it is. Never carried over from the
  /// stored value when the pin changes: a confirmed flag on a coordinate nobody
  /// looked at is the one lie this field must not tell.
  late bool _geoConfirmed = widget.spot?.geoConfirmed ?? false;

  bool _locating = false;

  bool get _isEdit => widget.spot != null;

  /// The address as typed, for seeding a geocoder query.
  String get _addressQuery => [
    _street.text.trim(),
    _postalCode.text.trim(),
    _city.text.trim(),
  ].where((part) => part.isNotEmpty).join(', ');

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
        geo: _geo,
        geoConfirmed: _geoConfirmed,
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

  /// Looks the typed address up and takes the pin from it.
  ///
  /// Leaves [_geoConfirmed] false — a geocoder puts the pin on the address, and
  /// the address is the front of the building. Which door a volunteer actually
  /// goes to is a different question, and only a person can answer it.
  ///
  /// With several candidates it hands over to the map rather than guessing:
  /// "Bahnhofstraße 12" exists in a hundred towns, and picking the first one
  /// silently is how somebody drives to the wrong one.
  Future<void> _lookUpPin() async {
    final l10n = context.l10n;
    final query = _addressQuery;
    if (query.isEmpty) {
      await _placePin();
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _locating = true);
    List<GeoResult> results;
    try {
      final repo = await ref.read(geocodingRepositoryProvider.future);
      results = await repo.forward(query);
    } on Object catch (error, stackTrace) {
      reportCaughtError(error, stackTrace, context: 'forward geocode');
      if (!mounted) return;
      setState(() => _locating = false);
      // Not a dead end: the map still works with the geocoder down.
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.spotPinLookupFailed)),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _locating = false);

    if (results.length == 1) {
      final only = results.single;
      setState(() {
        _geo = only.point;
        _geoConfirmed = false;
        markDirty();
      });
      // Names what it took. A plausible street in the wrong town is the failure
      // mode, and it is invisible unless the app says which one it chose.
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l10n.spotPinFoundOne(
              only.displayName.isEmpty ? query : only.displayName,
            ),
          ),
        ),
      );
      return;
    }
    await _placePin(seed: query);
  }

  /// Opens the map. A pin that comes back from here IS confirmed — somebody
  /// looked at the building and put it there.
  Future<void> _placePin({String? seed}) async {
    final picked = await showSpotPinPicker(
      context,
      initial: _geo,
      searchSeed: seed ?? _addressQuery,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _geo = picked.point;
      _geoConfirmed = true;
      markDirty();
    });
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
          _PinField(
            geo: _geo,
            confirmed: _geoConfirmed,
            busy: _locating || isBusy,
            onLookUp: _lookUpPin,
            onPlace: _placePin,
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

/// The pin's state, and the two ways to change it.
///
/// Shown even with no pin, and saying what that costs: a Spot with no
/// coordinates is findable by name but appears on no map, and the map is the
/// entry point for every round. A silent empty field would let that pass as
/// normal.
class _PinField extends StatelessWidget {
  const _PinField({
    required this.geo,
    required this.confirmed,
    required this.busy,
    required this.onLookUp,
    required this.onPlace,
  });

  final GeoPoint? geo;
  final bool confirmed;
  final bool busy;
  final Future<void> Function() onLookUp;
  final Future<void> Function() onPlace;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final point = geo;

    // Three states, three sentences. "Derived" and "confirmed" are NOT degrees
    // of the same thing: one is a guess at an address, the other is a person
    // who stood there.
    final (icon, label) = switch ((point, confirmed)) {
      (null, _) => (Icons.location_off_outlined, l10n.spotPinNone),
      (_, false) => (Icons.location_searching, l10n.spotPinFromAddress),
      (_, true) => (Icons.location_on, l10n.spotPinConfirmed),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: point == null
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.primary,
            ),
            const SizedBox(width: ZugvogelSpacing.sm),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.only(left: ZugvogelSpacing.sm),
                child: SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
          ],
        ),
        const SizedBox(height: ZugvogelSpacing.xs),
        Wrap(
          spacing: ZugvogelSpacing.sm,
          children: [
            TextButton.icon(
              onPressed: busy ? null : () => unawaited(onLookUp()),
              icon: const Icon(Icons.travel_explore, size: 18),
              label: Text(l10n.spotPinFindAction),
            ),
            TextButton.icon(
              onPressed: busy ? null : () => unawaited(onPlace()),
              icon: const Icon(Icons.map_outlined, size: 18),
              label: Text(l10n.spotPinSetAction),
            ),
          ],
        ),
      ],
    );
  }
}
