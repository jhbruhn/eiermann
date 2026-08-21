import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/spots/spot_labels.dart';
import 'package:eiermann/features/spots/spots_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Opens the sheet that moves [spot] to [target]. Resolves to true when the
/// move was written, null when the sheet was dismissed.
Future<bool?> showSpotPhaseSheet(
  BuildContext context, {
  required Spot spot,
  required SpotPhase target,
}) {
  return showAppSheet<bool>(
    context,
    builder: (_) => SpotPhaseSheet(spot: spot, target: target),
  );
}

/// One phase transition, and whatever that transition has to bring with it.
///
/// One sheet for all five moves rather than a dialog each. They share
/// everything that is hard — the busy state, the German the server answers with
/// when it refuses anyway, the discard guard over a half-typed reason — and
/// differ only in which fields they show. Five dialogs would be five places for
/// the error slot to be forgotten in.
///
/// It exists at all because the server enforces what a bare select could not
/// collect. `app_spot_phase.js` refuses a pause with no reason, a closing with
/// no reason, and an activation whose Erkundung never recorded its yes — so
/// before this sheet the edit sheet offered those moves and the user read a
/// refusal they had no way to act on.
class SpotPhaseSheet extends ConsumerStatefulWidget {
  const SpotPhaseSheet({required this.spot, required this.target, super.key});

  final Spot spot;

  /// The phase being moved to. Only ever one of the Spot's own
  /// `allowedPhases`, or [SpotPhase.paused] for a Spot already paused —
  /// the one target that is not a transition (`_isPauseEdit`).
  final SpotPhase target;

  @override
  ConsumerState<SpotPhaseSheet> createState() => _SpotPhaseSheetState();
}

class _SpotPhaseSheetState extends ConsumerState<SpotPhaseSheet>
    with DiscardGuard, FormSheetState {
  /// Prefilled only when a pause is being corrected — a NEW pause starts empty,
  /// because the server cleared the last one and the last one's reason is not
  /// this one's.
  late final _reason = TextEditingController(
    text: _isPauseEdit ? (widget.spot.pauseReason ?? '') : '',
  );

  /// Local, because a picker returns local and the field renders local. The
  /// conversion back to UTC happens once, in the repository's body.
  late DateTime? _until = _isPauseEdit
      ? widget.spot.pausedUntil?.toLocal()
      : null;

  ClosedReason? _closedReason;
  bool _consent = false;
  bool _closedReasonMissing = false;

  Spot get _spot => widget.spot;

  /// paused → paused: correcting a pause, not leaving one.
  ///
  /// Not in the transition graph, and deliberately not added to it: the
  /// graph is the server's and holds transitions only. This is an edit,
  /// which is why the menu labels it one.
  bool get _isPauseEdit =>
      _spot.phase == SpotPhase.paused && widget.target == SpotPhase.paused;

  /// Whether this activation also has to record the Zusage.
  bool get _recordsConsent =>
      widget.target == SpotPhase.active && _spot.activationRecordsConsent;

  /// Whether the closing reason is mandatory. False for a refused Erkundung —
  /// the refusal is already the reason.
  bool get _closedReasonRequired =>
      widget.target == SpotPhase.closed && _spot.closingNeedsReason;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  String _title(AppLocalizations l10n) => switch (widget.target) {
    SpotPhase.paused =>
      _isPauseEdit ? l10n.spotPauseEditTitle : l10n.spotPauseTitle,
    SpotPhase.closed => l10n.spotCloseTitle,
    SpotPhase.active => switch (_spot.phase) {
      SpotPhase.paused => l10n.spotResumeTitle,
      SpotPhase.closed => l10n.spotReopenTitle,
      _ => l10n.spotActivateTitle,
    },
    // Unreachable: nothing leads back to an Erkundung.
    SpotPhase.prospect => l10n.spotPhaseLabel,
  };

  String _saveLabel(AppLocalizations l10n) => _isPauseEdit
      ? l10n.actionSave
      : spotPhaseMoveLabel(l10n, _spot.phase ?? widget.target, widget.target);

  Future<void> _save() async {
    final l10n = context.l10n;
    final missing = _closedReasonRequired && _closedReason == null;
    if (_closedReasonMissing != missing) {
      setState(() => _closedReasonMissing = missing);
    }
    if (!(formKey.currentState?.validate() ?? false) || missing) return;
    if (_recordsConsent && !_consent) {
      // Named rather than shown as a field error: what is missing is not an
      // entry, it is the permission itself, and the sentence has to say what is
      // at stake instead of "please tick this".
      setSaveError(l10n.spotActivateConsentRequired);
      return;
    }

    final navigator = Navigator.of(context);
    final ok = await runSave(() async {
      final repo = await ref.read(spotsRepositoryProvider.future);
      await repo.update(
        _spot.id,
        SpotsRepository.phaseBody(
          phase: widget.target,
          pauseReason: _reason.text.trim(),
          pausedUntil: _until,
          closedReason: _closedReason,
          // The one field this sheet writes that is not part of the phase: the
          // Zusage the activation is asserting. Sent only when the box was
          // ticked, so nothing rewrites a funnel that already said yes.
          prospectStage: _recordsConsent ? ProspectStage.permitted : null,
        ),
      );
      // The dossier's header, and the list row's phase chip and due date — the
      // server just recomputed the date, so a stale row would show a Spot that
      // is paused and due at the same time.
      ref.invalidate(spotProvider(_spot.id));
      invalidateSpotViews(ref);
    });
    if (ok && mounted) navigator.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final strings = EiermannStrings(l10n);

    return guardUnsavedChanges(
      child: SheetScaffold(
        title: _title(l10n),
        formKey: formKey,
        onFormChanged: markDirty,
        isBusy: isBusy,
        error: saveError,
        onSave: _save,
        saveLabel: _saveLabel(l10n),
        saveIcon: spotPhaseIcon(widget.target),
        children: [
          _Explanation(_intro(l10n)),
          if (widget.target == SpotPhase.paused) ..._pauseFields(l10n, strings),
          if (widget.target == SpotPhase.closed) ..._closeFields(l10n),
          if (_recordsConsent) ..._consentFields(l10n),
        ],
      ),
    );
  }

  /// What this move does, in one sentence, before anything is asked for.
  ///
  /// Every mode has one, including the two that need no input: "Fortsetzen" and
  /// "Wieder öffnen" both silently delete a field somebody wrote, and a sheet
  /// whose only content is a button is a confirmation that confirms nothing.
  String _intro(AppLocalizations l10n) => switch (widget.target) {
    SpotPhase.paused => l10n.spotPauseIntro,
    SpotPhase.closed => l10n.spotCloseIntro,
    SpotPhase.active => switch (_spot.phase) {
      SpotPhase.paused => l10n.spotResumeIntro,
      SpotPhase.closed => l10n.spotReopenIntro,
      _ => l10n.spotActivateIntro,
    },
    SpotPhase.prospect => l10n.spotPhaseLabel,
  };

  List<Widget> _pauseFields(AppLocalizations l10n, EiermannStrings strings) => [
    const SizedBox(height: ZugvogelSpacing.md),
    AppTextField(
      controller: _reason,
      label: l10n.spotPauseFieldReason,
      hintText: l10n.spotPauseFieldReasonHint,
      prefixIcon: Icons.pause_circle_outline,
      enabled: !isBusy,
      autofocus: true,
      maxLines: 2,
      // The server refuses a pause without one. Refusing here as well is not
      // redundancy: it keeps the answer next to the empty field instead of in
      // an error slot under the button.
      validator: Validators.required(strings),
    ),
    _Footnote(l10n.spotPauseReasonWhy),
    const SizedBox(height: ZugvogelSpacing.md),
    DateField(
      label: l10n.spotPauseFieldUntil,
      placeholder: l10n.spotPauseFieldUntilPlaceholder,
      value: _until,
      enabled: !isBusy,
      onPick: _pickUntil,
      onClear: () => setState(() {
        _until = null;
        markDirty();
      }),
    ),
    // Says what the date DOES. It only started doing anything when the
    // auto-resume cron landed (eiermann-gb1): before that `paused_until` was a
    // note to a human, and "Voraussichtlich bis" was deliberately vague:
    // promising a return the app could not deliver is worse than silence.
    _Footnote(l10n.spotPauseUntilWhy),
  ];

  Future<void> _pickUntil() async {
    final today = DateTime.now();
    final picked = await pickDate(
      context,
      initial: _until ?? today.add(const Duration(days: 30)),
      firstDate: today,
      // Both bounds spelled out: `pickDate` defaults `lastDate` to today,
      // because most dates in these apps are observations. This one is a plan,
      // so every selectable day would otherwise be in the past.
      lastDate: DateTime(today.year + 3, today.month, today.day),
    );
    if (picked == null) return;
    setState(() {
      _until = picked;
      markDirty();
    });
  }

  List<Widget> _closeFields(AppLocalizations l10n) => [
    const SizedBox(height: ZugvogelSpacing.md),
    DropdownButtonFormField<ClosedReason?>(
      initialValue: _closedReason,
      decoration: InputDecoration(
        labelText: l10n.spotCloseFieldReason,
        prefixIcon: const Icon(Icons.block),
        errorText: _closedReasonMissing ? l10n.fieldRequired : null,
      ),
      items: [
        // Offered only where the server accepts it, so the list of choices is
        // never wider than the list of answers.
        if (!_closedReasonRequired)
          DropdownMenuItem(child: Text(l10n.spotCloseReasonNone)),
        for (final reason in ClosedReason.values)
          DropdownMenuItem(
            value: reason,
            child: Text(closedReasonLabel(l10n, reason)),
          ),
      ],
      onChanged: isBusy
          ? null
          : (reason) => setState(() {
              _closedReason = reason;
              _closedReasonMissing = false;
              markDirty();
            }),
    ),
    _Footnote(
      _closedReasonRequired
          ? l10n.spotCloseReasonWhy
          : l10n.spotCloseRefusedNote,
    ),
  ];

  List<Widget> _consentFields(AppLocalizations l10n) => [
    const SizedBox(height: ZugvogelSpacing.sm),
    CheckboxListTile(
      value: _consent,
      title: Text(l10n.spotActivateConsentTitle),
      // Names the stage it is about to overwrite. Somebody who believed the
      // Erkundung already said yes needs to see that it does not.
      subtitle: Text(
        l10n.spotActivateConsentHint(
          prospectStageLabel(
            l10n,
            _spot.prospectStage ?? ProspectStage.untouched,
          ),
        ),
      ),
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      onChanged: isBusy
          ? null
          : (value) => setState(() {
              _consent = value ?? false;
              markDirty();
            }),
    ),
  ];
}

/// The sentence at the top of the sheet: what this move does.
class _Explanation extends StatelessWidget {
  const _Explanation(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Why a field is worth filling in, under the field.
class _Footnote extends StatelessWidget {
  const _Footnote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(
        top: ZugvogelSpacing.xs,
        left: ZugvogelSpacing.md,
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
