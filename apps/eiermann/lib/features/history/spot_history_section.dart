import 'dart:async';

import 'package:eiermann/features/findings/finding_correction_sheet.dart';
import 'package:eiermann/features/findings/finding_labels.dart';
import 'package:eiermann/features/history/history_providers.dart';
import 'package:eiermann/features/visits/check_labels.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// The dossier's chronology: what has happened at this building, newest first.
///
/// **One list, not three sections.** A check and a Fund exist only because
/// somebody was at the building, so each visit carries its own — federfall's
/// rule that one consistent view beats fragmented sections, and the reason is
/// concrete: three lists ordered by three dates make the reader join them by
/// hand to answer "what happened on the 14th".
///
/// It renders INSIDE the dossier's own scroll view rather than owning one. That
/// is what lets it be the last block on the page — the history is what you read
/// after the things you act on — and it means the dossier's scroll drives the
/// paging: the tail only builds when somebody has scrolled to it, so opening a
/// Spot costs one page and not the whole history.
class SpotHistorySection extends ConsumerWidget {
  const SpotHistorySection({required this.spotId, super.key});

  final String spotId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final history = ref.watch(spotHistoryProvider(spotId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const IconChip(Icons.history),
            const SizedBox(width: ZugvogelSpacing.md),
            Expanded(
              child: Text(
                l10n.spotHistoryTitle,
                style: theme.textTheme.titleMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: ZugvogelSpacing.sm),
        AsyncValueView<SpotHistoryState>(
          value: history,
          onRetry: () => ref.invalidate(spotHistoryProvider(spotId)),
          data: (state) => state.entries.isEmpty
              ? Text(
                  l10n.spotHistoryEmpty,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final entry in state.entries) _VisitCard(entry),
                    if (state.hasMore)
                      PagedListTail(
                        error: state.pageError,
                        onLoad: () => unawaited(
                          ref
                              .read(spotHistoryProvider(spotId).notifier)
                              .loadMore(),
                        ),
                        onRetry: () => unawaited(
                          ref
                              .read(spotHistoryProvider(spotId).notifier)
                              .retryPage(),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// One visit, and everything recorded on it.
class _VisitCard extends StatelessWidget {
  const _VisitCard(this.entry);

  final VisitEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final materialL10n = MaterialLocalizations.of(context);
    final visit = entry.visit;
    final skipped = visit.outcome == VisitOutcome.skipped;
    final when = visit.visitedAt;

    return Card(
      margin: const EdgeInsets.only(bottom: ZugvogelSpacing.sm),
      child: Padding(
        padding: const EdgeInsets.all(ZugvogelSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  // A skip is a different KIND of entry, not a failed visit:
                  // nobody there is a fact about the building.
                  skipped ? Icons.block_outlined : Icons.check_circle_outline,
                  size: 20,
                  color: skipped
                      ? theme.colorScheme.onSurfaceVariant
                      : context.zvColors.good,
                ),
                const SizedBox(width: ZugvogelSpacing.sm),
                Expanded(
                  child: Text(
                    // Through formatLocalDate like every date in this app:
                    // PocketBase stores UTC, and after 22:00 CET a raw render
                    // is a day out — which in a chronology reorders nothing but
                    // makes every entry wrong.
                    when == null
                        ? l10n.spotHistoryNoDate
                        : formatLocalDate(materialL10n, when),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                // The name and not the id: a closed account must not take the
                // visits it made with it, so the snapshot is what a history can
                // actually show.
                if (visit.authorName case final name?)
                  Text(
                    name,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            if (skipped) ...[
              const SizedBox(height: ZugvogelSpacing.xs),
              Text(
                [
                  l10n.visitSkipTitle,
                  skipReasonLabel(l10n, visit.skipReason),
                  ?visit.skipNote,
                ].join(' · '),
                style: theme.textTheme.bodyMedium,
              ),
            ] else ...[
              const SizedBox(height: ZugvogelSpacing.xs),
              Text(
                _summary(l10n),
                style: theme.textTheme.bodyMedium,
              ),
            ],
            for (final check in entry.checks)
              _Line(
                icon: checkStateIcon(check.state),
                colour: checkStateColor(context, check.state),
                text: [
                  // A check with no nest label is an id nobody can act on, so
                  // the fallback names the gap rather than printing a token.
                  check.nestLabel ?? l10n.spotHistoryUnknownNest,
                  checkStateLabel(l10n, check.state),
                  ?check.note,
                ].join(' · '),
              ),
            // The Fund lines are the only tappable ones here, and that
            // asymmetry is the collection's: a `nest_check` has no update rule
            // at all — the nest's rhythm and its egg counts are derived from
            // those rows, so an edited check would leave the derived state
            // describing a visit that did not happen. A Fund's DESCRIPTION was
            // always meant to be correctable (eiermann-8fw).
            for (final finding in entry.findings)
              _Line(
                icon: findingKindIcon(finding.kind),
                colour: findingKindColor(context, finding.kind),
                text: [
                  findingSummary(
                    l10n,
                    finding.kind,
                    count: finding.count,
                    speciesLabel: finding.speciesLabel,
                    nestLabel: finding.nestLabel,
                  ),
                  ?finding.note,
                ].join(' · '),
                onTap: () => showFindingCorrectionSheet(
                  context,
                  finding: finding,
                ),
                tapHint: l10n.findingCorrectAction,
              ),
            if (visit.note case final note?) ...[
              const SizedBox(height: ZugvogelSpacing.xs),
              Text(
                note,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// What the visit did, in one line — the same three numbers the flow reports
  /// on the way back to the car, read off the STORED checks this time.
  String _summary(AppLocalizations l10n) => [
    l10n.visitFlowSummaryRemoved(entry.removedReal),
    if (entry.addedDummy > 0) l10n.visitFlowSummaryDummies(entry.addedDummy),
    if (entry.halfClutches.isNotEmpty)
      l10n.visitFlowSummaryHalfClutch(entry.halfClutches.length),
    if (entry.findings.isNotEmpty)
      l10n.visitFlowSummaryFindings(entry.findings.length),
  ].join(' · ');
}

/// One indented line under a visit: a check or a Fund.
class _Line extends StatelessWidget {
  const _Line({
    required this.icon,
    required this.colour,
    required this.text,
    this.onTap,
    this.tapHint,
  });

  final IconData icon;
  final Color colour;
  final String text;

  /// What tapping this line does, or null for a line that only reports.
  final VoidCallback? onTap;

  /// What the tap is FOR, for a reader who cannot see the row.
  ///
  /// A timeline line is a `Row` of small text, not a control anything
  /// announces, so without this a screen reader offers "tap to activate" over a
  /// sentence about a dead bird. Required in practice wherever [onTap] is set.
  final String? tapHint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = Padding(
      padding: const EdgeInsets.only(
        top: ZugvogelSpacing.xs,
        left: ZugvogelSpacing.lg,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: colour),
          const SizedBox(width: ZugvogelSpacing.sm),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
          if (onTap != null) ...[
            const SizedBox(width: ZugvogelSpacing.sm),
            // A visible affordance and not only a tap target: the line looks
            // like every other line in the timeline, and nothing else here is
            // tappable.
            Icon(
              Icons.edit_outlined,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return line;
    return Semantics(
      button: true,
      hint: tapHint,
      child: InkWell(onTap: onTap, child: line),
    );
  }
}
