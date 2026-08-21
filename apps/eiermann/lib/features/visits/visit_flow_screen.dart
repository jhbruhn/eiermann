import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/nests/nest_labels.dart';
import 'package:eiermann/features/nests/nest_list.dart';
import 'package:eiermann/features/nests/nests_providers.dart';
import 'package:eiermann/features/visits/check_labels.dart';
import 'package:eiermann/features/visits/nest_check_sheet.dart';
import 'package:eiermann/features/visits/packing_card.dart';
import 'package:eiermann/features/visits/visit_skip_sheet.dart';
import 'package:eiermann/features/visits/visits_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_core/zugvogel_core.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// The Besuchsablauf: work through the nests of one building, then send it all
/// at once.
///
/// **Everything is in memory until the last button.** That is the mitigation
/// for having no offline mode, and a deliberate trade rather than a gap: in a
/// cellar with no signal exactly ONE call fails, at a named point, with a retry
/// that is safe to press three times because the Idempotency-Key is generated
/// once per visit. The form survives losing reception; it does not survive the
/// app being killed, and that is a stated limit.
///
/// It is also why there is no per-nest write. A visit assembled from seven REST
/// calls that breaks after the second one leaves a visit in which five nests
/// were not checked — and that is indistinguishable from five nests somebody
/// deliberately did not touch. Both are "no check row". No later screen can
/// tell them apart, and no repair is possible, because the information was
/// never recorded.
class VisitFlowScreen extends ConsumerStatefulWidget {
  const VisitFlowScreen({
    required this.spotId,
    this.startSkipped = false,
    super.key,
  });

  final String spotId;

  /// Opens the "nicht geprüft" sheet on arrival — where the dossier's second
  /// button leads.
  ///
  /// The two buttons are equal rank on the dossier because the two outcomes
  /// are: nobody there is a fact about the building. They lead to ONE screen so
  /// there is one submit path, one retry path and one idempotency key, rather
  /// than a second copy of all three behind a different button.
  final bool startSkipped;

  @override
  ConsumerState<VisitFlowScreen> createState() => _VisitFlowScreenState();
}

class _VisitFlowScreenState extends ConsumerState<VisitFlowScreen> {
  final _note = TextEditingController();

  /// What has been recorded so far, by nest id.
  final Map<String, NestCheckDraft> _checks = {};

  /// The key for THIS visit, generated on the first send and kept for every
  /// retry.
  ///
  /// Kept in the state and not regenerated, which is the whole safety
  /// property: the server stores the response under it and replays it instead
  /// of writing a second visit. A fresh key per attempt would turn "press it
  /// three times" into three visits, three sets of checks and a rhythm
  /// advanced three times.
  String? _key;

  bool _busy = false;
  String? _error;

  /// The draft the last failed attempt tried to send.
  ///
  /// The retry has to resend THAT ONE, not whatever the screen would build now.
  /// A failed "nicht geprüft" followed by a retry that sent a *checked* visit
  /// would reuse the same Idempotency-Key for a different body — which the
  /// server refuses with a 409, correctly, and the volunteer would be looking
  /// at "your key is being reused" for having pressed the button the app
  /// offered them.
  VisitDraft? _lastAttempt;

  /// Whether the last failure might have landed anyway.
  ///
  /// A client-side timeout abandons the request but cannot cancel it, so the
  /// visit may be written. The copy has to say so — and the retry is still the
  /// right move, because the key makes it safe.
  bool _outcomeUnknown = false;

  @override
  void initState() {
    super.initState();
    if (widget.startSkipped) {
      // After the first frame: the sheet needs a Navigator, and the screen is
      // still being built.
      WidgetsBinding.instance.addPostFrameCallback((_) => _skip());
    }
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _openNest(NestState nest) async {
    final draft = await showNestCheckSheet(
      context,
      nest: nest,
      existing: _checks[nest.id],
    );
    if (!mounted) return;
    setState(() {
      // Null is "discard this entry", and it must actually remove the nest from
      // the visit: an unchecked nest is a legitimate outcome, and leaving a
      // stale draft behind would record something nobody confirmed.
      if (draft == null) {
        _checks.remove(nest.id);
      } else {
        _checks[nest.id] = draft;
      }
    });
  }

  Future<void> _skip() async {
    final skip = await showVisitSkipSheet(context);
    if (skip == null || !mounted) return;
    await _send(
      VisitDraft(
        spot: widget.spotId,
        outcome: VisitOutcome.skipped,
        skipReason: skip.reason,
        skipNote: skip.note,
        note: _noteOrNull,
        // A skipped visit cannot carry checks — the endpoint refuses it, and
        // for a reason worth repeating: a check inside a non-event would be an
        // observation, and the rhythm would advance on a nest nobody saw.
      ),
    );
  }

  /// Sends the visit as recorded, or resends the attempt that failed.
  ///
  /// One button for both, because it is one operation: the same body under the
  /// same key. A separate control would suggest a different, riskier action.
  Future<void> _finishOrRetry() => _send(
    _lastAttempt ??
        VisitDraft(
          spot: widget.spotId,
          outcome: VisitOutcome.checked,
          note: _noteOrNull,
          checks: _checks.values.toList(),
        ),
  );

  String? get _noteOrNull {
    final text = _note.text.trim();
    return text.isEmpty ? null : text;
  }

  /// Sends [draft], or replays the attempt that failed.
  Future<void> _send(VisitDraft draft) async {
    final l10n = context.l10n;
    final strings = EiermannStrings(l10n);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    setState(() {
      _busy = true;
      _error = null;
      _outcomeUnknown = false;
      _lastAttempt = draft;
    });
    // Generated ONCE per visit, here rather than per attempt.
    final key = _key ??= newIdempotencyKey();

    try {
      final repo = await ref.read(visitsRepositoryProvider.future);
      final result = await repo.submit(draft, idempotencyKey: key);
      if (!mounted) return;
      // Everything a visit touches at once: the eggs, the nests' rhythm state,
      // the Spot's date, the follow-ups.
      invalidateAfterVisit(ref);
      messenger.showSnackBar(
        SnackBar(content: Text(_summary(l10n, draft, result))),
      );
      navigator.pop();
    } on RepositoryException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _outcomeUnknown = e.kind == RepositoryErrorKind.unknownOutcome;
        _error = errorMessage(strings, e);
      });
    } on Object catch (error, stackTrace) {
      reportCaughtError(error, stackTrace, context: 'submit visit');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = strings.errorGenericTitle;
      });
    }
  }

  /// What the visit did, in one line — the confirmation somebody reads while
  /// walking back to the car.
  String _summary(
    AppLocalizations l10n,
    VisitDraft draft,
    VisitResult result,
  ) {
    if (draft.outcome == VisitOutcome.skipped) return l10n.visitSkipTitle;
    return [
      l10n.visitFlowSummaryRemoved(draft.removedReal),
      if (draft.addedDummy > 0) l10n.visitFlowSummaryDummies(draft.addedDummy),
      // From the RESULT, not from the draft: the server has the last word on
      // the Halbgelege, and this is the confirmation that the Nachkontrolle
      // exists.
      if (result.halfClutches.isNotEmpty)
        l10n.visitFlowSummaryHalfClutch(result.halfClutches.length),
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final nests = ref.watch(nestStatesForSpotProvider(widget.spotId));

    return PopScope(
      // Leaving throws away work nothing else holds: the recorded nests, or an
      // attempt that failed and is still waiting to be resent. A successful
      // send pops programmatically, which PopScope does not intercept.
      canPop: _checks.isEmpty && _lastAttempt == null && !_busy,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await _confirmLeave() && mounted) navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.visitFlowTitle)),
        body: AsyncValueView(
          value: nests,
          onRetry: () =>
              ref.invalidate(nestStatesForSpotProvider(widget.spotId)),
          data: (rows) => ContentBounds(
            child: ListView(
              padding: const EdgeInsets.all(ZugvogelSpacing.lg),
              children: [
                PackingCard(nests: rows),
                const SizedBox(height: ZugvogelSpacing.lg),
                Text(
                  l10n.visitFlowNestsTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: ZugvogelSpacing.sm),
                if (rows.isEmpty)
                  Text(
                    l10n.visitFlowNoNests,
                    style: Theme.of(context).textTheme.bodyMedium,
                  )
                else
                  for (final nest in rows)
                    _NestRow(
                      nest: nest,
                      draft: _checks[nest.id],
                      onTap: _busy ? null : () => _openNest(nest),
                    ),
                const SizedBox(height: ZugvogelSpacing.lg),
                AppTextField(
                  controller: _note,
                  label: l10n.visitFlowNoteLabel,
                  prefixIcon: Icons.notes_outlined,
                  enabled: !_busy,
                  maxLines: 3,
                ),
                const SizedBox(height: ZugvogelSpacing.lg),
                if (_error case final message?) ...[
                  _SendFailure(
                    message: message,
                    outcomeUnknown: _outcomeUnknown,
                  ),
                  const SizedBox(height: ZugvogelSpacing.md),
                ],
                Text(
                  l10n.visitFlowProgress(_checks.length, rows.length),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: ZugvogelSpacing.sm),
                PrimaryButton(
                  // The retry is the SAME action with the same key, so it is
                  // the same button — a separate "erneut senden" control would
                  // suggest a different, riskier operation.
                  label: _error == null
                      ? l10n.visitFlowFinishAction
                      : l10n.visitFlowRetryAction,
                  icon: _error == null ? Icons.check : Icons.refresh,
                  isLoading: _busy,
                  onPressed: _finishOrRetry,
                ),
                const SizedBox(height: ZugvogelSpacing.sm),
                // Equal rank, not an error path: nobody there is a fact about
                // the building.
                OutlinedButton.icon(
                  // Withdrawn once an attempt has gone out: the key belongs to
                  // that body now, and starting a different visit under it is
                  // the 409 the retry exists to avoid. The way out of a failed
                  // send is the retry, or leaving.
                  onPressed: _busy || _lastAttempt != null ? null : _skip,
                  icon: const Icon(Icons.block_outlined),
                  label: Text(l10n.visitSkipAction),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<bool> _confirmLeave() async {
    final l10n = context.l10n;
    final leave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.visitFlowLeaveTitle),
        content: Text(l10n.visitFlowLeaveMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.visitFlowLeaveKeep),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.visitFlowLeaveConfirm),
          ),
        ],
      ),
    );
    return leave ?? false;
  }
}

/// One nest, and what this visit has recorded about it so far.
class _NestRow extends StatelessWidget {
  const _NestRow({
    required this.nest,
    required this.draft,
    required this.onTap,
  });

  final NestState nest;
  final NestCheckDraft? draft;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final recorded = draft;
    final state = recorded?.effectiveState;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        recorded == null
            ? nestSpeciesIcon(nest.species)
            : checkStateIcon(state),
        color: recorded == null
            ? nestSpeciesColor(context, nest.species)
            : checkStateColor(context, state),
      ),
      title: Text(nest.label),
      subtitle: Text(
        // Before it is checked the line says what is IN the nest — which is
        // what tells somebody whether to bother climbing. Afterwards it says
        // what they did, because that is the thing they might want to correct.
        recorded == null
            ? [
                ?nest.positionHint,
                if (nest.isProtected)
                  l10n.nestProtectedDoNotTouch
                else
                  nestContent(l10n, nest),
              ].join(' · ')
            : checkStateLabel(l10n, state),
        style: theme.textTheme.bodySmall?.copyWith(
          color: recorded != null && state == CheckState.partial
              ? context.zvColors.warning
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: recorded == null
          ? Text(
              l10n.visitFlowNestOpen,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : const Icon(Icons.check),
      onTap: onTap,
    );
  }
}

/// The failure block: what happened, and that nothing is lost.
///
/// The second sentence is the load-bearing one. A volunteer who thinks the work
/// is gone stops recording — so the copy says the visit is still in the app and
/// that sending again cannot produce a second one. That promise is the
/// Idempotency-Key made concrete, and it is stated exactly where the failure
/// appears.
class _SendFailure extends StatelessWidget {
  const _SendFailure({required this.message, required this.outcomeUnknown});

  final String message;

  /// Whether the write may have landed anyway. The retry stays the right move —
  /// the key makes it safe — but the sentence must not claim "not reached".
  final bool outcomeUnknown;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(ZugvogelSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.visitFlowSendFailedTitle,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: ZugvogelSpacing.xs),
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: ZugvogelSpacing.xs),
            Text(
              // Both halves are true whether or not the outcome is known: the
              // draft is still here, and the key is what makes pressing again
              // safe either way.
              l10n.visitFlowSendFailedHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
                fontWeight: outcomeUnknown ? FontWeight.bold : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
