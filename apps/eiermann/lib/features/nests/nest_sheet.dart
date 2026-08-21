import 'package:eiermann/core/auth/roles.dart';
import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/nests/nest_labels.dart';
import 'package:eiermann/features/nests/nests_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/ui/form_sheet.dart';
import 'package:eiermann/ui/photo_capture.dart';
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

  /// A photo taken in this sheet, not yet uploaded.
  ///
  /// Staged rather than sent at once — unlike the Bereich photo, which is what
  /// a Bereich is FOR and has nothing to wait for. A nest photo is one field of
  /// a form somebody is still filling in, and a photo that uploaded itself
  /// while the label was still wrong would be a half-saved nest. It travels
  /// with the create, so a new nest is still ONE request.
  CapturedPhoto? _photo;

  /// The stored photo is to be removed on save.
  ///
  /// Removable, again unlike the Bereich photo: that one carries the pins, and
  /// dropping it strands them. A nest photo carries nothing but itself.
  bool _photoRemoved = false;

  /// The filename still on the record, unless this save drops it.
  String? get _storedPhoto => _photoRemoved ? null : widget.nest?.photo;

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
        // Only on the way OUT: a new file goes as a multipart part below.
        clearPhoto: _photoRemoved && _photo == null,
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
      // One request either way, photo included: a nest that existed for a
      // moment without its picture is a nest somebody else can already see.
      final photo = _photo;
      final files = photo == null ? null : [photoPart('photo', photo)];
      if (existing == null) {
        if (files == null) {
          await repo.create(body);
        } else {
          await repo.createWithFiles(body, files);
        }
      } else {
        if (files == null) {
          await repo.update(existing.id, body);
        } else {
          await repo.updateWithFiles(existing.id, body, files);
        }
      }
      // Both reads: the editor's pins come from `nests`, the dossier's list
      // from the view over it.
      invalidateNestViews(ref);
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
          _PhotoField(
            nestId: widget.nest?.id,
            stored: _storedPhoto,
            staged: _photo,
            enabled: !isBusy,
            onCapture: () async {
              final photo = await capturePhoto(
                context,
                ref,
                filenameStem: 'nest',
              );
              // Null is "backed out", which must leave what was there alone —
              // including a removal the reader had already asked for.
              if (photo == null || !mounted) return;
              setState(() {
                _photo = photo;
                _photoRemoved = false;
                markDirty();
              });
            },
            onRemove: () => setState(() {
              _photo = null;
              _photoRemoved = true;
              markDirty();
            }),
          ),
          const SizedBox(height: ZugvogelSpacing.md),
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

/// The nest's own photo, as one field of the sheet.
///
/// Three states, and the difference matters: nothing yet, something stored on
/// the record, and something taken here but not yet saved. The staged one is
/// drawn from memory — there is no URL for a file that has not been uploaded —
/// and it is what a reader sees change when they take a picture, which is the
/// only feedback that the tap did anything.
class _PhotoField extends ConsumerWidget {
  const _PhotoField({
    required this.nestId,
    required this.stored,
    required this.staged,
    required this.enabled,
    required this.onCapture,
    required this.onRemove,
  });

  /// Null while the nest is being created — there is no record to build a file
  /// URL against yet, which is exactly why the photo is staged.
  final String? nestId;

  final String? stored;
  final CapturedPhoto? staged;
  final bool enabled;
  final VoidCallback onCapture;
  final VoidCallback onRemove;

  static const double _size = 96;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final repo = ref.watch(nestsRepositoryProvider).value;
    final id = nestId;

    final Widget picture;
    if (staged case final photo?) {
      picture = Image.memory(photo.bytes, fit: BoxFit.cover);
    } else if (stored != null && id != null && repo != null) {
      // `cover` is CachedFileImage's default and the right one here: this is a
      // thumbnail of a close-up, not a surface anything is measured against.
      picture = CachedFileImage(
        url: repo.fileUrl(id, stored!, thumb: '600x600'),
      );
    } else {
      picture = Icon(
        Icons.add_a_photo_outlined,
        color: theme.colorScheme.onSurfaceVariant,
      );
    }

    final hasPhoto = staged != null || stored != null;

    return Row(
      children: [
        SizedBox(
          width: _size,
          height: _size,
          child: Material(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: enabled ? onCapture : null,
              child: Center(child: picture),
            ),
          ),
        ),
        const SizedBox(width: ZugvogelSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.nestFieldPhoto, style: theme.textTheme.labelLarge),
              const SizedBox(height: ZugvogelSpacing.xs),
              Text(
                // Says what the nest photo is for, because the Bereich photo
                // already showed WHERE it is: this one answers what it looks
                // like from up close, which is what tells two ledges apart.
                l10n.nestPhotoHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: ZugvogelSpacing.xs),
              Wrap(
                spacing: ZugvogelSpacing.sm,
                children: [
                  TextButton.icon(
                    onPressed: enabled ? onCapture : null,
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: Text(
                      hasPhoto
                          ? l10n.nestPhotoReplaceAction
                          : l10n.nestPhotoSetAction,
                    ),
                  ),
                  if (hasPhoto)
                    TextButton.icon(
                      onPressed: enabled ? onRemove : null,
                      icon: const Icon(Icons.delete_outline),
                      label: Text(l10n.photoRemoveAction),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
