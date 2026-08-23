import 'package:eiermann/features/findings/finding_labels.dart';
import 'package:eiermann/features/reports/report_sheet.dart';
import 'package:eiermann/features/spots/spot_labels.dart';
import 'package:eiermann/features/statistics/egg_series_chart.dart';
import 'package:eiermann/features/statistics/period_selector.dart';
import 'package:eiermann/features/statistics/statistics_providers.dart';
import 'package:eiermann/features/visits/check_labels.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/routing/back_or_home.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Die Zahlen: what a period of work came to.
///
/// ── The client aggregates NOTHING ──────────────────────────────────────────
///
/// Every figure on this screen arrives from `GET /api/eiermann/stats` already
/// computed. Not an optimisation: it is the same aggregation the printed report
/// runs, so the screen and the PDF cannot contradict each other — which matters
/// because somebody WILL put them side by side in front of an authority. A
/// second implementation here would disagree the first time either was touched.
///
/// ── Rates are shares of a completed denominator ────────────────────────────
///
/// And they are null, not 0 %, while nothing has completed. A rate is a
/// measurement; zero is a claim. Each rate tile therefore carries its
/// denominator as a note INSIDE the tile — a caption under the grid would
/// qualify every tile in it.
class StatisticsScreen extends ConsumerWidget {
  const StatisticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final period = ref.watch(statisticsPeriodProvider);
    final stats = ref.watch(
      statisticsProvider(year: period.year, month: period.month),
    );

    return BackOrHomeScope(
      child: Scaffold(
        appBar: AppBar(
          // Reached by `go` from the account menu, so there can be nothing
          // beneath it — a cold open, a web reload, or an arrival from a tab.
          // `AppBar`'s implied arrow vanishes in exactly that case.
          leading: const BackOrHomeButton(),
          title: Text(l10n.statsTitle),
          actions: [
            IconButton(
              icon: const Icon(Icons.ios_share),
              tooltip: l10n.statsExportAction,
              // Available even while the figures are loading or failed: the
              // export is a server-side render over the same period and does
              // not need this screen's payload to succeed. Only the year
              // PICKER in the sheet leans on it, and it degrades to the two
              // recent years.
              onPressed: () => showReportSheet(context),
            ),
          ],
        ),
        body: AsyncValueView(
          value: stats,
          onRetry: () => ref.invalidate(
            statisticsProvider(year: period.year, month: period.month),
          ),
          data: (data) => _Figures(stats: data, period: period),
        ),
      ),
    );
  }
}

class _Figures extends ConsumerWidget {
  const _Figures({required this.stats, required this.period});

  final OrgStatistics stats;
  final StatsPeriod period;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;

    return RefreshIndicator(
      onRefresh: () => ref.refresh(
        statisticsProvider(year: period.year, month: period.month).future,
      ),
      child: ListView(
        // Always scrollable, so pull-to-refresh works on a period that fits.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(ZugvogelSpacing.md),
        children: [
          ContentBounds(
            child: PeriodSelector(
              selected: period,
              // Org-wide regardless of the period shown, which is what lets the
              // picker leave the year it is on.
              visitYears: stats.visitYears,
              onChanged: (picked) =>
                  ref.read(statisticsPeriodProvider.notifier).select(picked),
            ),
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          if (stats.isEmpty)
            // A period with no visits is not an error and not an empty app: the
            // group has simply not been out. Everything below would be a page
            // of zeros, and a page of zeros reads as a failure of the work.
            ContentBounds(
              child: EmptyView(
                icon: Icons.insights_outlined,
                title: l10n.statsEmptyTitle,
                message: l10n.statsEmptyMessage,
                actionLabel: l10n.statsExportAction,
                actionIcon: Icons.ios_share,
                onAction: () => showReportSheet(context),
              ),
            )
          else ...[
            ContentBounds(child: _Kpis(stats: stats)),
            const SizedBox(height: ZugvogelSpacing.md),
            ContentBounds(child: _SeriesCard(stats: stats)),
            const SizedBox(height: ZugvogelSpacing.md),
            ContentBounds(child: _CheckStatesCard(stats: stats)),
            const SizedBox(height: ZugvogelSpacing.md),
            ContentBounds(child: _FindingsCard(stats: stats)),
            if (stats.findingSpecies.isNotEmpty) ...[
              const SizedBox(height: ZugvogelSpacing.md),
              ContentBounds(child: _SpeciesCard(stats: stats)),
            ],
            if (stats.visitsSkipped > 0) ...[
              const SizedBox(height: ZugvogelSpacing.md),
              ContentBounds(child: _SkipReasonsCard(stats: stats)),
            ],
            const SizedBox(height: ZugvogelSpacing.md),
            ContentBounds(child: _AddressesCard(stats: stats)),
          ],
          // Outside the `isEmpty` branch on purpose: how far the group's access
          // reaches is true whether or not anybody went out in the selected
          // period, and it is the one block here a brand-new group can read.
          if (!stats.spots.isEmpty) ...[
            const SizedBox(height: ZugvogelSpacing.md),
            ContentBounds(child: _SpotsCard(stats: stats)),
          ],
        ],
      ),
    );
  }
}

/// A 0–1 share as a whole percent, or an en dash while the rate is undefined.
///
/// Undefined is not zero: nothing has been attempted yet, and "0 %" would be a
/// statement about the work rather than about the data.
String _rate(AppLocalizations l10n, double? value) => value == null
    ? '–'
    : l10n.statsPercentValue(
        // Through the injected strings, not the raw l10n: the decimal
        // separator is one of the three injection seams, and a hard-coded
        // point is how "3.5" reaches a German reader.
        formatNumber(EiermannStrings(l10n), value * 100, maxFractionDigits: 0),
      );

class _Kpis extends StatelessWidget {
  const _Kpis({required this.stats});

  final OrgStatistics stats;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return KpiGrid([
      KpiCard(
        icon: Icons.directions_walk_outlined,
        label: l10n.statsVisits,
        value: '${stats.visits}',
        note: l10n.statsVisitsNote(stats.spotsVisited),
      ),
      KpiCard(
        icon: Icons.egg_outlined,
        label: l10n.statsEggsRemoved,
        value: '${stats.eggsRemoved}',
        note: l10n.statsEggsRemovedNote(stats.dummiesPlaced),
      ),
      KpiCard(
        icon: Icons.checklist_outlined,
        label: l10n.statsChecks,
        value: '${stats.checks}',
        // The mean over trips that GOT IN. A trip nobody got into had no chance
        // to remove an egg, so it is not in the denominator.
        note: stats.eggsPerCheckedVisit == null
            ? l10n.statsChecksNoteNone
            : l10n.statsChecksNote(
                formatNumber(
                  EiermannStrings(l10n),
                  stats.eggsPerCheckedVisit!,
                ),
              ),
      ),
      KpiCard(
        icon: Icons.key_outlined,
        label: l10n.statsAccessRate,
        value: _rate(l10n, stats.accessRate),
        // Its denominator, inside the tile: every trip made, because a trip
        // nobody got into is exactly what makes this figure interesting.
        note: l10n.statsAccessRateNote(stats.visits),
      ),
      KpiCard(
        icon: Icons.swap_horiz_outlined,
        label: l10n.statsFullSwapRate,
        value: _rate(l10n, stats.fullSwapRate),
        // NOT over all checks: over the clutches actually found. Over every
        // check it would sag whenever the team finds more empty nests, which is
        // when the work is going well.
        note: l10n.statsFullSwapRateNote(_clutchesFound),
      ),
      KpiCard(
        icon: Icons.pest_control_outlined,
        label: l10n.statsFindings,
        value: '${stats.findings}',
      ),
    ]);
  }

  /// The clutches actually encountered: swapped clean plus half-swapped. The
  /// denominator [OrgStatistics.fullSwapRate] is computed over, restated here
  /// so the tile can name it.
  int get _clutchesFound => stats.checkStates
      .where(
        (c) => c.value == CheckState.swapped || c.value == CheckState.partial,
      )
      .fold(0, (sum, c) => sum + c.count);
}

class _SeriesCard extends StatelessWidget {
  const _SeriesCard({required this.stats});

  final OrgStatistics stats;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(ZugvogelSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.statsSeriesTitle, style: theme.textTheme.titleMedium),
            const SizedBox(height: ZugvogelSpacing.md),
            EggSeriesChart(series: stats.series),
          ],
        ),
      ),
    );
  }
}

class _CheckStatesCard extends StatelessWidget {
  const _CheckStatesCard({required this.stats});

  final OrgStatistics stats;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // A pie, because this IS a partition: every check is in exactly one state
    // and the counts sum to `checks`. Three hues plus "Sonstige" — the ring is
    // there to show the shape, and the rows below carry every state with its
    // exact count.
    final entries = [
      for (final c in stats.checkStates)
        if (c.count > 0) ChartEntry(checkStateLabel(l10n, c.value), c.count),
    ];
    return BreakdownCard(
      title: l10n.statsCheckStatesTitle,
      chart: BreakdownPie(entries: entries, otherLabel: l10n.statsChartOther),
      rows: [
        // In the enum's DECLARED order, not by count: this is a census of one
        // enum, and a reader comparing two periods needs the same order in
        // both. Zeros are kept for the same reason — a state that did not
        // happen is a reading, and dropping it makes the rows stop summing to
        // the total.
        for (final c in stats.checkStates)
          BreakdownRow(checkStateLabel(l10n, c.value), c.count),
      ],
      footnote: l10n.statsCheckStatesFootnote(stats.checks),
      emptyMessage: l10n.statsEmptySection,
    );
  }
}

class _FindingsCard extends StatelessWidget {
  const _FindingsCard({required this.stats});

  final OrgStatistics stats;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final entries = [
      for (final f in stats.findingKinds)
        if (f.count > 0) ChartEntry(findingKindLabel(l10n, f.value), f.count),
    ];
    return BreakdownCard(
      title: l10n.statsFindingsTitle,
      chart: BreakdownPie(entries: entries, otherLabel: l10n.statsChartOther),
      rows: [
        for (final f in stats.findingKinds)
          BreakdownRow(findingKindLabel(l10n, f.value), f.count),
      ],
      emptyMessage: l10n.statsFindingsEmpty,
    );
  }
}

class _SpeciesCard extends StatelessWidget {
  const _SpeciesCard({required this.stats});

  final OrgStatistics stats;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return BreakdownCard(
      title: l10n.statsSpeciesTitle,
      // BARS and not a ring: a Fund may carry a species label or none, so these
      // counts do not partition the Funde and a ring would draw a picture its
      // own percentages contradict. Each bar's length is its share of the
      // period's Funde and nothing else.
      chart: BreakdownBars(
        entries: [
          for (final s in stats.findingSpecies) ChartEntry(s.label, s.count),
        ],
        total: stats.findings,
        caption: l10n.statsSpeciesCaption,
      ),
      rows: [
        // The labels are FREE TEXT somebody typed at a nest. Two spellings are
        // two rows, and nothing normalises behind the reader's back — the price
        // the vocabulary pays for never going stale.
        for (final s in stats.findingSpecies) BreakdownRow(s.label, s.count),
      ],
      emptyMessage: l10n.statsEmptySection,
    );
  }
}

class _SkipReasonsCard extends StatelessWidget {
  const _SkipReasonsCard({required this.stats});

  final OrgStatistics stats;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return BreakdownCard(
      // The list a request for a key is argued with: "kein Schlüssel, elf Mal".
      title: l10n.statsSkipReasonsTitle,
      chart: BreakdownBars(
        entries: [
          for (final s in stats.skipReasons)
            ChartEntry(skipReasonLabel(l10n, s.value), s.count),
        ],
        total: stats.visitsSkipped,
        caption: l10n.statsSkipReasonsCaption,
      ),
      rows: [
        for (final s in stats.skipReasons)
          BreakdownRow(skipReasonLabel(l10n, s.value), s.count),
      ],
      footnote: l10n.statsSkipReasonsFootnote(stats.visitsSkipped),
      emptyMessage: l10n.statsEmptySection,
    );
  }
}

class _AddressesCard extends StatelessWidget {
  const _AddressesCard({required this.stats});

  final OrgStatistics stats;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return BreakdownCard(
      title: l10n.statsAddressesTitle,
      chart: BreakdownBars(
        entries: [
          for (final a in stats.addresses) ChartEntry(a.label, a.count),
        ],
        total: stats.visits,
        caption: l10n.statsAddressesCaption,
      ),
      rows: [
        // Every address, uncapped. An org with sixty buildings has sixty rows,
        // and a reader must never be left wondering whether the tail they
        // cannot see is two visits or twenty.
        for (final a in stats.addresses) BreakdownRow(a.label, a.count),
      ],
      emptyMessage: l10n.statsEmptySection,
    );
  }
}

class _SpotsCard extends StatelessWidget {
  const _SpotsCard({required this.stats});

  final OrgStatistics stats;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final spots = stats.spots;
    return BreakdownCard(
      title: l10n.statsSpotsTitle,
      chart: BreakdownPie(
        entries: [
          for (final p in spots.phases)
            if (p.count > 0) ChartEntry(spotPhaseLabel(l10n, p.value), p.count),
        ],
        otherLabel: l10n.statsChartOther,
      ),
      rows: [
        for (final p in spots.phases)
          BreakdownRow(spotPhaseLabel(l10n, p.value), p.count),
        // The funnel under the phases rather than in a card of its own: these
        // rows are a breakdown OF the `prospect` row above them, and separating
        // them would invite adding the two lists together.
        for (final s in spots.prospectStages)
          if (s.value case final stage?)
            BreakdownRow(
              prospectStageLabel(l10n, stage),
              s.count,
              subtitle: l10n.statsSpotsStageSubtitle,
            ),
      ],
      // Says what the reader is looking at: NOT the selected period. Without
      // this line, picking 2024 would read as "we had four buildings in 2024".
      footnote: l10n.statsSpotsFootnote(spots.total),
      emptyMessage: l10n.statsEmptySection,
    );
  }
}
