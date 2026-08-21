import 'package:eiermann/features/visits/check_labels.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// What a skipped visit records.
typedef VisitSkip = ({SkipReason reason, String? note});

/// Asks why the visit did not happen, and returns it. Null means backed out.
Future<VisitSkip?> showVisitSkipSheet(BuildContext context) {
  return showAppSheet<VisitSkip>(
    context,
    builder: (_) => const VisitSkipSheet(),
  );
}

/// "Nicht geprüft", with a reason — an equal-rank outcome, not an error path.
///
/// Somebody stood in front of the building and did not get in. That is a fact
/// about the building worth recording, and the app's answer to a group whose
/// list would otherwise fill up with buildings nobody can explain.
///
/// The reason is mandatory, and the sheet says why the visit does NOT move the
/// rhythm: a volunteer who believed "nicht geprüft" clears the entry would use
/// it to tidy the list, and the building would drop out of the rhythm — which
/// is the one direction this app must never drift.
class VisitSkipSheet extends ConsumerStatefulWidget {
  const VisitSkipSheet({super.key});

  @override
  ConsumerState<VisitSkipSheet> createState() => _VisitSkipSheetState();
}

class _VisitSkipSheetState extends ConsumerState<VisitSkipSheet>
    with DiscardGuard, FormSheetState {
  final _note = TextEditingController();
  SkipReason? _reason;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _confirm() {
    final reason = _reason;
    if (reason == null) {
      // Refused here rather than by the server, for the reason the server also
      // refuses it: a skip with no cause cannot say whether anybody tried.
      setSaveError(context.l10n.visitSkipReasonMissing);
      return;
    }
    final note = _note.text.trim();
    Navigator.of(context).pop((
      reason: reason,
      note: note.isEmpty ? null : note,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return guardUnsavedChanges(
      child: SheetScaffold(
        title: l10n.visitSkipTitle,
        formKey: formKey,
        onFormChanged: markDirty,
        isBusy: isBusy,
        error: saveError,
        onSave: _confirm,
        saveLabel: l10n.visitSkipConfirmAction,
        saveIcon: Icons.block_outlined,
        children: [
          Text(l10n.visitSkipReasonLabel, style: theme.textTheme.labelLarge),
          const SizedBox(height: ZugvogelSpacing.sm),
          Wrap(
            spacing: ZugvogelSpacing.sm,
            runSpacing: ZugvogelSpacing.sm,
            children: [
              for (final reason in SkipReason.values)
                ChoiceChip(
                  selected: _reason == reason,
                  label: Text(skipReasonLabel(l10n, reason)),
                  onSelected: (_) => setState(() {
                    _reason = reason;
                    markDirty();
                  }),
                ),
            ],
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          AppTextField(
            controller: _note,
            label: l10n.visitSkipNoteLabel,
            prefixIcon: Icons.notes_outlined,
            maxLines: 2,
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          Text(
            l10n.visitSkipHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
