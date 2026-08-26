import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/findings/finding_labels.dart';
import 'package:eiermann/features/findings/finding_sheet.dart';
import 'package:eiermann/features/history/history_providers.dart';
import 'package:eiermann/features/species/species_label_field.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Opens the sheet that corrects what a recorded Fund SAYS.
///
/// Returns true when something was written, so a caller holding its own copy of
/// the row knows to stop trusting it.
Future<bool> showFindingCorrectionSheet(
  BuildContext context, {
  required Finding finding,
}) async =>
    await showAppSheet<bool>(
      context,
      builder: (_) => FindingCorrectionSheet(finding: finding),
    ) ??
    false;

/// Correct a Fund after the fact — the note, the species name, the count.
///
/// **Not the same sheet as [FindingSheet], deliberately.** That one edits a
/// [FindingDraft] the visit has not sent yet: it may still change the kind and
/// the nest, because nothing has been recorded and the reader is describing
/// what is in front of them. This one edits a row that exists, and the two
/// questions differ in exactly the way the collection's update rule does.
///
/// What may change is the DESCRIPTION. "Das war eine Dohle, keine Ringeltaube"
/// is what somebody realises on the way home, and `1700000011` has allowed that
/// write since the collection existed — the rule stood and the surface did not,
/// so a Fund was immutable in the app although the server never meant it.
///
/// What may not change is the EVENT: the kind, the nest, the building, the
/// visit. Those are not offered rather than offered-and-refused, and the kind
/// is SHOWN read-only above the fields, because a form that hid it would invite
/// somebody to fix "toter Vogel" by rewriting the note underneath it. If the
/// kind is wrong the record is wrong, and that is a different conversation from
/// this one.
class FindingCorrectionSheet extends ConsumerStatefulWidget {
  const FindingCorrectionSheet({required this.finding, super.key});

  final Finding finding;

  @override
  ConsumerState<FindingCorrectionSheet> createState() =>
      _FindingCorrectionSheetState();
}

class _FindingCorrectionSheetState extends ConsumerState<FindingCorrectionSheet>
    with DiscardGuard, FormSheetState {
  late final _species = TextEditingController(
    text: widget.finding.speciesLabel ?? '',
  );
  late final _note = TextEditingController(text: widget.finding.note ?? '');

  /// The stored count, floored at 1. A row written by something other than the
  /// visit endpoint can hold 0 — `Finding.fromRecord` shows that as it is
  /// rather than as 1 — but the stepper cannot go below one, and silently
  /// saving a 1 over a 0 nobody looked at would be this sheet inventing a fact.
  /// So it opens at 1 and the save is the reader's.
  late int _count = widget.finding.count < 1 ? 1 : widget.finding.count;

  /// Whether a species name is a question worth asking for this kind.
  ///
  /// The same rule [FindingSheet] applies, and it has to be: netting has no
  /// species, and a field under it invites somebody to type the building
  /// material. A Fund recorded before that rule existed could still carry one,
  /// which is why the field also appears when there is something to CLEAR.
  bool get _wantsSpecies =>
      widget.finding.kind != FindingKind.siteChange ||
      (widget.finding.speciesLabel ?? '').isNotEmpty;

  @override
  void dispose() {
    _species.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(formKey.currentState?.validate() ?? false)) return;
    final navigator = Navigator.of(context);

    final ok = await runSave(() async {
      final repo = await ref.read(findingsRepositoryProvider.future);
      await repo.correct(
        widget.finding.id,
        count: _count,
        note: trimToNull(_note),
        speciesLabel: _wantsSpecies ? trimToNull(_species) : null,
      );
      // A Fund appears in the chronology, in the org-wide list and behind the
      // dashboard's number. All three are the same row, so all three go —
      // a list still showing "Ringeltaube" after the correction reads as a
      // write that did not happen.
      invalidateHistoryViews(ref);
    });
    if (ok && mounted) navigator.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return guardUnsavedChanges(
      child: SheetScaffold(
        title: l10n.findingCorrectTitle,
        formKey: formKey,
        onFormChanged: markDirty,
        isBusy: isBusy,
        error: saveError,
        onSave: _save,
        saveLabel: l10n.findingCorrectSaveAction,
        children: [
          _WhatThisWas(finding: widget.finding),
          const SizedBox(height: ZugvogelSpacing.lg),
          FindingCountStepper(
            count: _count,
            max: FindingCountStepper.max20,
            onChanged: (value) => setState(() {
              _count = value;
              markDirty();
            }),
          ),
          if (_wantsSpecies) ...[
            const SizedBox(height: ZugvogelSpacing.md),
            SpeciesLabelField(
              controller: _species,
              label: l10n.findingSpeciesLabel,
              enabled: !isBusy,
              onPicked: markDirty,
            ),
          ],
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

/// The part of the Fund that is not up for correction, stated plainly.
///
/// Shown rather than left out: the fields below are a description OF something,
/// and a form that opened straight onto an empty note would let somebody
/// correct the wrong Fund without noticing. The sentence underneath says which
/// way out exists, because a control that is simply absent reads as an
/// oversight rather than as a decision.
class _WhatThisWas extends StatelessWidget {
  const _WhatThisWas({required this.finding});

  final Finding finding;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final materialL10n = MaterialLocalizations.of(context);
    final when = finding.foundAt;

    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(ZugvogelSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              findingKindIcon(finding.kind),
              color: findingKindColor(context, finding.kind),
            ),
            const SizedBox(width: ZugvogelSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    [
                      findingKindLabel(l10n, finding.kind),
                      // An id with no label next to it is a bug in this app, so
                      // the nest is named or not mentioned at all.
                      ?finding.nestLabel,
                      if (when != null) formatLocalDate(materialL10n, when),
                      ?finding.authorName,
                    ].join(' · '),
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: ZugvogelSpacing.xs),
                  Text(
                    l10n.findingCorrectEventFixed,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
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
