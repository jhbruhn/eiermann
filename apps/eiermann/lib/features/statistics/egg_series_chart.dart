import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Entnommene Eier im Zeitverlauf: one bar per day of the selected month, per
/// month of the selected year, or per calendar year over all time — with the
/// SAME period a year earlier beside each bar where there is one.
///
/// ── Why eggs and not visits ────────────────────────────────────────────────
///
/// Both numbers are in the payload and only one can be the bar. Eggs removed is
/// the one this chart is for: it is the work's effect on the colony, it is what
/// a funder and a Behörde are shown, and it is seasonal — which is exactly what
/// a bar chart with last year beside it answers. The visit count is in the
/// tooltip, because "12 Eier aus 4 Besuchen" is the reading that makes a low
/// bar interpretable: a month of six visits that found empty nests is a GOOD
/// month, and a chart of eggs alone would draw it as a bad one.
///
/// The comparison sits BESIDE each bar rather than stacked behind it — stacked,
/// the two would read as a sum, which they are not.
///
/// Every bucket the server sent is drawn, zeros included: a February nobody
/// went out in is a fact about the year, not a gap in the chart.
class EggSeriesChart extends StatelessWidget {
  const EggSeriesChart({required this.series, super.key});

  final VisitSeries series;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    final points = series.points;
    if (points.isEmpty) {
      return Text(
        l10n.statsEmptySection,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      );
    }

    // Aligned by KEY, not by position: the comparison period is a full period
    // of its own, so a month missing from it must read as zero rather than
    // shift every later bar one column left.
    final previousByKey = {
      for (final p in series.previousPoints) p.key: p.removed,
    };
    final hasPrevious = series.hasPrevious;

    var tallest = 0;
    for (final p in points) {
      tallest = p.removed > tallest ? p.removed : tallest;
    }
    for (final removed in previousByKey.values) {
      tallest = removed > tallest ? removed : tallest;
    }
    // Four gridlines at most, on whole eggs — half an egg is not a reading.
    final step = (tallest / 4).ceil().clamp(1, 1 << 30);
    // The ceiling is the next multiple of that step, not `tallest + step`:
    // fl_chart labels maxY whatever it is, so a top off the interval prints
    // 0, 3, 6, 9, 12, 14 with the last two labels nearly touching.
    final ceiling = (tallest ~/ step + 1) * step;

    final label = _bucketLabel(context);
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final monthFormat = DateFormat.MMM(
      Localizations.localeOf(context).toString(),
    );
    String monthName(int m) => monthFormat.format(DateTime(2000, m));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasPrevious) ...[
          _Legend(
            currentLabel: _currentLabel(l10n, series, monthName),
            previousLabel: _previousLabel(series, monthName),
          ),
          const SizedBox(height: ZugvogelSpacing.sm),
        ],
        LayoutBuilder(
          builder: (context, constraints) {
            // What one bucket actually gets on this screen: the plot is what is
            // left once the value axis has taken its own width.
            final (bucketLabel, labelEvery) = _axisLabels(
              context,
              (constraints.maxWidth - _valueAxisWidth) / points.length,
              label,
            );
            return SizedBox(
              height: 180,
              child: BarChart(
                BarChartData(
                  maxY: ceiling.toDouble(),
                  gridData: chartGrid(context, interval: step.toDouble()),
                  borderData: FlBorderData(show: false),
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      // Inverse surface rather than fl_chart's blue-grey: the
                      // default draws body ink on a dark box, and a tooltip on
                      // an edge bar gets clipped by the chart's own canvas.
                      getTooltipColor: (_) => colors.inverseSurface,
                      fitInsideHorizontally: true,
                      fitInsideVertically: true,
                      getTooltipItem: (group, groupIndex, rod, rodIndex) {
                        final point = points[groupIndex];
                        // Which bucket AND which period — with two rods per
                        // group the number alone would be ambiguous.
                        final period = !hasPrevious
                            ? ''
                            : rodIndex == 0
                            ? ' ${_previousLabel(series, monthName)}'
                            : ' ${_currentLabel(l10n, series, monthName)}';
                        // The visit count only for the SELECTED period's rod:
                        // the payload carries no per-bucket visit count for the
                        // comparison series, and inventing one from the current
                        // period would be a number about the wrong year.
                        final visits = hasPrevious && rodIndex == 0
                            ? ''
                            : '\n${l10n.statsChartTooltipVisits(point.visits)}';
                        return BarTooltipItem(
                          '${label(point.key)}$period: '
                          '${l10n.statsChartTooltipEggs(rod.toY.toInt())}'
                          '$visits',
                          theme.textTheme.labelMedium?.copyWith(
                                color: colors.onInverseSurface,
                              ) ??
                              TextStyle(color: colors.onInverseSurface),
                        );
                      },
                    ),
                  ),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(),
                    rightTitles: const AxisTitles(),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: _valueAxisWidth,
                        interval: step.toDouble(),
                        getTitlesWidget: (value, meta) => axisLabel(
                          meta,
                          meta.formattedValue,
                          style: labelStyle,
                          fitInside: false,
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 24,
                        getTitlesWidget: (value, meta) {
                          final i = value.toInt();
                          if (i < 0 || i >= points.length) {
                            return const SizedBox.shrink();
                          }
                          if (i % labelEvery != 0) {
                            return const SizedBox.shrink();
                          }
                          return axisLabel(
                            meta,
                            bucketLabel(points[i].key),
                            style: labelStyle,
                          );
                        },
                      ),
                    ),
                  ),
                  barGroups: [
                    for (var i = 0; i < points.length; i++)
                      BarChartGroupData(
                        x: i,
                        barsSpace: 2,
                        barRods: [
                          // The comparison period FIRST, so time reads left to
                          // right inside each group as it does across the axis.
                          if (hasPrevious)
                            BarChartRodData(
                              toY: (previousByKey[points[i].key] ?? 0)
                                  .toDouble(),
                              width: 7,
                              borderRadius: _rodEnd,
                              color: colors.primaryContainer,
                            ),
                          BarChartRodData(
                            toY: points[i].removed.toDouble(),
                            width: hasPrevious ? 7 : 10,
                            borderRadius: _rodEnd,
                            color: colors.primary,
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  /// The selected period's own name for the legend: the year, or the month and
  /// year when a month is selected — the comparison is the SAME month a year
  /// earlier, so the month alone would name both series.
  static String _currentLabel(
    AppLocalizations l10n,
    VisitSeries series,
    String Function(int) monthName,
  ) {
    final previous = series.previousYear;
    if (previous == null) return l10n.statsPeriodAllTime;
    final month = series.previousMonth;
    return month == null
        ? '${previous + 1}'
        : '${monthName(month)} ${previous + 1}';
  }

  /// The comparison period's name, on the same pattern.
  static String _previousLabel(
    VisitSeries series,
    String Function(int) monthName,
  ) {
    final month = series.previousMonth;
    return month == null
        ? '${series.previousYear}'
        : '${monthName(month)} ${series.previousYear}';
  }

  /// Rounded at the data end, square on the baseline. fl_chart rounds every
  /// corner by default, so each bar stands on a half-circle that crosses the
  /// zero line — a one-egg month then reads as a lozenge hanging off the axis
  /// rather than as a bar standing on it.
  static const BorderRadius _rodEnd = BorderRadius.vertical(
    top: Radius.circular(3),
  );

  /// What the left axis reserves, and therefore what the plot does not get.
  static const double _valueAxisWidth = 32;

  /// How the bottom axis is labelled in the width it actually has: the label
  /// for a bucket key, and how many buckets there are between labels.
  ///
  /// EVERY month is named. Reading this chart means mapping a bar to a month,
  /// and a label every third column makes that a counting exercise. Where three
  /// letters do not fit a column — a phone showing twelve months — the locale's
  /// single-letter form does, and in calendar order it is still read as months.
  /// Days and years have no shorter form and keep labelling every nth: 31 days
  /// cannot all be named side by side.
  (String Function(int), int) _axisLabels(
    BuildContext context,
    double column,
    String Function(int) label,
  ) {
    switch (series.kind) {
      case SeriesBucket.day:
        return (label, 5);
      case SeriesBucket.year:
        return (label, (series.points.length / 6).ceil().clamp(1, 1 << 30));
      case SeriesBucket.month:
        return fittingAxisLabels(
          context,
          column: column,
          keys: [for (final p in series.points) p.key],
          preferred: label,
          fallback: narrowMonthLabel(context),
          style: Theme.of(context).textTheme.labelSmall,
        );
    }
  }

  /// Bucket key → axis label: a short month name, or the number itself.
  String Function(int) _bucketLabel(BuildContext context) {
    if (series.kind != SeriesBucket.month) return (key) => '$key';
    // MaterialLocalizations has no bare short-month format, and slicing one out
    // of formatShortMonthDay would depend on the locale's field order.
    final month = DateFormat.MMM(Localizations.localeOf(context).toString());
    return (key) => month.format(DateTime(2000, key));
  }
}

/// Which colour is this period and which is the one behind it.
class _Legend extends StatelessWidget {
  const _Legend({required this.currentLabel, required this.previousLabel});

  final String currentLabel;
  final String previousLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Wrap(
      spacing: ZugvogelSpacing.md,
      runSpacing: ZugvogelSpacing.xs,
      children: [
        _LegendEntry(color: colors.primary, label: currentLabel),
        _LegendEntry(color: colors.primaryContainer, label: previousLabel),
      ],
    );
  }
}

class _LegendEntry extends StatelessWidget {
  const _LegendEntry({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: ZugvogelSpacing.xs),
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
