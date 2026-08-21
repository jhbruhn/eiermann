import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/areas/areas_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/ui/form_sheet.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Opens the sheet that adds a Bereich to [spotId], or edits [area].
Future<void> showAreaSheet(
  BuildContext context, {
  required String spotId,
  Area? area,
}) {
  return showAppSheet<void>(
    context,
    builder: (_) => AreaSheet(spotId: spotId, area: area),
  );
}

/// Add or rename a Bereich — a named part of a building.
///
/// Only the name is required, and the photo is deliberately NOT part of this
/// form: a Bereich has to exist before a file can be attached to it, and asking
/// for both at once would mean either a two-step save that can half-fail or a
/// camera opening out of a form somebody is still typing in. The card that
/// appears afterwards asks for the photo, in the place where the photo goes.
class AreaSheet extends ConsumerStatefulWidget {
  const AreaSheet({required this.spotId, this.area, super.key});

  /// The Spot the Bereich belongs to. Frozen on the edit path — the collection
  /// refuses a re-parenting write, and it would take the nests with it.
  final String spotId;

  final Area? area;

  @override
  ConsumerState<AreaSheet> createState() => _AreaSheetState();
}

class _AreaSheetState extends ConsumerState<AreaSheet>
    with DiscardGuard, FormSheetState {
  late final _name = TextEditingController(text: widget.area?.name ?? '');
  late final _note = TextEditingController(text: widget.area?.note ?? '');

  bool get _isEdit => widget.area != null;

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(formKey.currentState?.validate() ?? false)) return;
    final navigator = Navigator.of(context);
    final existing = widget.area;

    final ok = await runSave(() async {
      final repo = await ref.read(areasRepositoryProvider.future);
      final body = AreasRepository.body(
        name: _name.text.trim(),
        note: trimToNull(_note),
        // Both only on create: the collection freezes the parent and pins the
        // org, so an update carrying either is refused outright.
        spot: existing == null ? widget.spotId : null,
        org: existing == null ? (await requireUserOrg()).$2 : null,
      );
      if (existing == null) {
        await repo.create(body);
      } else {
        await repo.update(existing.id, body);
      }
      ref.invalidate(areasForSpotProvider(widget.spotId));
    });
    if (ok && mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final strings = EiermannStrings(l10n);

    return guardUnsavedChanges(
      child: SheetScaffold(
        title: _isEdit ? l10n.areaSheetTitleEdit : l10n.areaSheetTitleNew,
        formKey: formKey,
        onFormChanged: markDirty,
        isBusy: isBusy,
        error: saveError,
        onSave: _save,
        children: [
          AppTextField(
            controller: _name,
            label: l10n.areaFieldName,
            hintText: l10n.areaFieldNameHint,
            prefixIcon: Icons.meeting_room_outlined,
            enabled: !isBusy,
            autofocus: !_isEdit,
            textInputAction: TextInputAction.next,
            validator: Validators.required(strings),
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          AppTextField(
            controller: _note,
            label: l10n.areaFieldNote,
            // What a photo cannot say and a pin cannot either: how to get up
            // there, and what to watch out for on the way.
            hintText: l10n.areaFieldNoteHint,
            prefixIcon: Icons.notes_outlined,
            enabled: !isBusy,
            maxLines: 3,
          ),
        ],
      ),
    );
  }
}
