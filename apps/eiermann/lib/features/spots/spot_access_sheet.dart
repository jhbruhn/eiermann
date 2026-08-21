import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/spots/spots_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Opens the one-field editor for [spot]'s access note. Resolves to true when
/// it was written.
Future<bool?> showSpotAccessSheet(BuildContext context, {required Spot spot}) {
  return showAppSheet<bool>(
    context,
    builder: (_) => SpotAccessSheet(spot: spot),
  );
}

/// The access note, on its own, in one field.
///
/// The Spot edit sheet can already reach this field, so this is deliberate
/// duplication. The reason is where it gets used: somebody is standing at a
/// door having just learned which bell to ring, on a phone, one-handed. Through
/// the edit sheet that is four taps and a scroll past the address; here it is
/// one tap on the card that was showing them the gap.
///
/// It is the field the concept calls the answer to "die Übergabe ist
/// schmerzhaft" — the one line that saves the next person a phone call — so it
/// gets the shortest possible path from noticing to written down.
class SpotAccessSheet extends ConsumerStatefulWidget {
  const SpotAccessSheet({required this.spot, super.key});

  final Spot spot;

  @override
  ConsumerState<SpotAccessSheet> createState() => _SpotAccessSheetState();
}

class _SpotAccessSheetState extends ConsumerState<SpotAccessSheet>
    with DiscardGuard, FormSheetState {
  late final _accessNote = TextEditingController(
    text: widget.spot.accessNote ?? '',
  );

  @override
  void dispose() {
    _accessNote.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final navigator = Navigator.of(context);
    final ok = await runSave(() async {
      final repo = await ref.read(spotsRepositoryProvider.future);
      await repo.update(
        widget.spot.id,
        // One key, not the form's body: this sheet owns one field and must not
        // rewrite the five it never showed. Emptied deliberately writes '' —
        // removing a note that has gone stale is as much the point as adding
        // one, and a wrong access note is worse than none.
        {'access_note': _accessNote.text.trim()},
      );
      ref.invalidate(spotProvider(widget.spot.id));
      // Neither the list row nor the map callout draws the note, but the view
      // carries it and a future one will.
      invalidateSpotViews(ref);
    });
    if (ok && mounted) navigator.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return guardUnsavedChanges(
      child: SheetScaffold(
        title: l10n.spotAccessSheetTitle,
        formKey: formKey,
        onFormChanged: markDirty,
        isBusy: isBusy,
        error: saveError,
        onSave: _save,
        children: [
          Text(
            l10n.spotAccessSheetIntro,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          AppTextField(
            controller: _accessNote,
            label: l10n.spotFieldAccessNote,
            hintText: l10n.spotFieldAccessNoteHint,
            prefixIcon: Icons.key_outlined,
            enabled: !isBusy,
            autofocus: true,
            // Roomier than the same field in the Spot form: this is where the
            // long version gets written — which bell, which key, who unlocks,
            // and when they are actually there.
            maxLines: 5,
          ),
        ],
      ),
    );
  }
}
