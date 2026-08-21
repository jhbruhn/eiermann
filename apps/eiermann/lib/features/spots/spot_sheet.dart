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

/// Create or edit a Spot: what it is called, WHERE IT IS, how you get in.
///
/// **The pin is the location; the address is a label.** That order is the
/// design, and it is the opposite of what a form usually does. A pigeon Spot is
/// frequently not at an address: a light well between two blocks, a bridge
/// underside, the back of a courtyard reached through a different building's
/// gate. Making the address the source of the location means those Spots either
/// get a neighbouring building's address — precise, official-looking and wrong
/// — or get no location at all and disappear off the map.
///
/// So the pin comes first, it is offered on its own terms, and the address
/// fields below it are what a person writes for another person ("Ecke
/// Bahnhofstraße / Am Wall"). The geocoder's answer for the pin is shown as
/// CONTEXT next to it and never written into those fields: auto-filling them
/// is exactly how a Spot between buildings acquires a wrong address.
///
/// The pin is still not required. A building somebody walked past is worth
/// recording before anybody has stood in front of it, and the form says what a
/// missing pin costs rather than refusing the save.
///
/// `geo_confirmed` records which kind of pin it is. Searching an address inside
/// the picker leaves it false — a geocoder lands on the postal address, which
/// may be the wrong side of the courtyard; moving the map by hand sets it. The
/// dossier and the map both show the difference.
///
/// **The phase is offered on CREATE only, and only the two phases a Spot can
/// start in.** Pausing and closing need a reason the server insists on, so they
/// live on the dossier's phase chip where the reason gets collected. A dropdown
/// here that offered them was a dropdown whose only function was to produce a
/// refusal.
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
  /// there is no permission yet, which is the honest default.
  ///
  /// Only ever read on the create path — an edit does not touch the phase at
  /// all, so an existing Spot whose stored phase this build cannot read is
  /// left exactly as it is rather than being rewritten by a form that had to
  /// put something in the field.
  SpotPhase _phase = SpotPhase.prospect;

  /// The only two phases a Spot can START in.
  ///
  /// `paused` and `closed` are states the lifecycle produces, not states
  /// anybody begins in — and both need a reason the server refuses to do
  /// without, which this form has nowhere to ask for. Offering them here meant
  /// offering two guaranteed refusals out of four.
  static const List<SpotPhase> _startPhases = [
    SpotPhase.prospect,
    SpotPhase.active,
  ];

  late GeoPoint? _geo = widget.spot?.geo;

  /// Whether a person put THIS pin where it is. Never carried over from the
  /// stored value when the pin changes: a confirmed flag on a coordinate nobody
  /// looked at is the one lie this field must not tell.
  late bool _geoConfirmed = widget.spot?.geoConfirmed ?? false;

  /// What the geocoder made of the current pin, for the line under the control.
  /// Only ever set by the picker — this form never asks a geocoder itself.
  GeoResult? _resolved;

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
    if (!(formKey.currentState?.validate() ?? false)) return;
    final navigator = Navigator.of(context);
    final existing = widget.spot;

    String? writtenId;
    final ok = await runSave(() async {
      final repo = await ref.read(spotsRepositoryProvider.future);
      final body = SpotsRepository.body(
        name: _name.text.trim(),
        // On an edit, the phase the Spot already has — this form has no control
        // for it, and the dossier's chip owns every change to it. Null for a
        // stored phase this build cannot name, which `body` then omits rather
        // than rewriting.
        phase: existing == null ? _phase : existing.phase,
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

      invalidateSpotViews(ref);
      if (existing != null) ref.invalidate(spotProvider(existing.id));
    });
    if (ok && mounted) navigator.pop(writtenId);
  }

  /// Opens the map so somebody can put the pin where the Spot actually is.
  ///
  /// The ONLY route to a pin from this form, and that is deliberate. There used
  /// to be a second one — "look it up from the address" — which quietly made
  /// the address the source of the location. For a Spot in a light well between
  /// two blocks that is the wrong answer dressed as a precise one. The picker
  /// still has address search inside it, seeded from whatever is typed here, so
  /// nothing got slower; it just is not this form's answer to "where is this".
  ///
  /// A pin that comes back from here IS confirmed: somebody looked at the map
  /// and put it there.
  Future<void> _placePin() async {
    final picked = await showSpotPinPicker(
      context,
      initial: _geo,
      searchSeed: _addressQuery,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _geo = picked.point;
      _geoConfirmed = true;
      // Kept for the line under the control, NOT written into the address
      // fields. Filling those from a geocoder is exactly how a Spot between
      // buildings acquires a neighbour's address.
      _resolved = picked.resolved;
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
          // FIRST after the name, because it IS the location — see the class
          // doc.
          _PinField(
            geo: _geo,
            confirmed: _geoConfirmed,
            resolved: _resolved,
            busy: isBusy,
            onPlace: _placePin,
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          // Under the pin and introduced as a hint, because that is what it is
          // here: something a person writes for another person. A Spot in a
          // courtyard may have no address of its own, and these fields stay
          // empty rather than borrowing a neighbour's.
          Text(
            l10n.spotAddressAsLabel,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: ZugvogelSpacing.sm),
          AppTextField(
            controller: _street,
            label: l10n.spotFieldStreet,
            hintText: l10n.spotFieldStreetHint,
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
          // CREATE only, and only the two phases a Spot can start in. Pausing
          // and closing need a reason the server insists on, and the dossier's
          // phase chip is where that gets collected.
          if (!_isEdit) ...[
            const SizedBox(height: ZugvogelSpacing.md),
            DropdownButtonFormField<SpotPhase>(
              initialValue: _phase,
              decoration: InputDecoration(
                labelText: l10n.spotPhaseLabel,
                prefixIcon: const Icon(Icons.flag_outlined),
                helperText: l10n.spotPhaseStartHint,
                helperMaxLines: 3,
              ),
              items: [
                for (final phase in _startPhases)
                  DropdownMenuItem(
                    value: phase,
                    child: Text(spotPhaseLabel(l10n, phase)),
                  ),
              ],
              onChanged: isBusy
                  ? null
                  : (phase) => setState(() {
                      // Non-null in practice: the list has no null entry, so a
                      // selection is always one of the two.
                      _phase = phase ?? SpotPhase.prospect;
                      markDirty();
                    }),
            ),
          ],
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

/// The location: the pin, what the map says is there, and the way to change it.
///
/// A card rather than a row of buttons, because it is not one field among six —
/// it is the answer to "where is this Spot", which for a pigeon Spot is a place
/// on a map and often not an address. Prominent when empty for the same reason
/// the access card is: a Spot with no pin is findable by name and appears on no
/// map, and the map is the entry point for every round.
class _PinField extends StatelessWidget {
  const _PinField({
    required this.geo,
    required this.confirmed,
    required this.resolved,
    required this.busy,
    required this.onPlace,
  });

  final GeoPoint? geo;
  final bool confirmed;

  /// What the geocoder made of this pin, when the picker got an answer. Shown
  /// as context, never written into the address fields.
  final GeoResult? resolved;

  final bool busy;
  final Future<void> Function() onPlace;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final point = geo;

    // Three states, three sentences. "Derived" and "confirmed" are NOT degrees
    // of the same thing: one is a geocoder's guess at a postal address, the
    // other is a person who looked at the map.
    final (icon, label) = switch ((point, confirmed)) {
      (null, _) => (Icons.location_off_outlined, l10n.spotPinNone),
      (_, false) => (Icons.location_searching, l10n.spotPinFromAddress),
      (_, true) => (Icons.location_on, l10n.spotPinConfirmed),
    };

    return Card(
      color: point == null
          ? theme.colorScheme.surfaceContainerHighest
          : theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(ZugvogelSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  color: point == null
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.onSecondaryContainer,
                ),
                const SizedBox(width: ZugvogelSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.spotFieldPin,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: point == null
                              ? theme.colorScheme.onSurfaceVariant
                              : theme.colorScheme.onSecondaryContainer,
                        ),
                      ),
                      const SizedBox(height: ZugvogelSpacing.xs),
                      Text(
                        label,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: point == null
                              ? theme.colorScheme.onSurfaceVariant
                              : theme.colorScheme.onSecondaryContainer,
                        ),
                      ),
                      // The coordinates, so a pin is verifiable without opening
                      // the map again — and readable out loud to somebody on
                      // the phone, which is what happens when two people are
                      // trying to find the same courtyard.
                      if (point != null) ...[
                        const SizedBox(height: ZugvogelSpacing.xs),
                        Text(
                          l10n.spotPinCoordinates(
                            point.lat.toStringAsFixed(5),
                            point.lon.toStringAsFixed(5),
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                        ),
                      ],
                      // What the map thinks is there. Context, not data: the
                      // address fields below are the person's to write, and a
                      // Spot between two blocks must not inherit a neighbour's
                      // address just because the geocoder had one to offer.
                      if (resolved?.displayName case final address?
                          when address.isNotEmpty) ...[
                        const SizedBox(height: ZugvogelSpacing.xs),
                        Text(
                          l10n.spotPinAccordingToMap(address),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSecondaryContainer,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: ZugvogelSpacing.sm),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.tonalIcon(
                onPressed: busy ? null : () => unawaited(onPlace()),
                icon: const Icon(Icons.map_outlined),
                label: Text(
                  point == null
                      ? l10n.spotPinSetAction
                      : l10n.spotPinMoveAction,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
