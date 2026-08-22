import 'package:eiermann/features/statistics/statistics_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// The years offered behind the "frühere Jahre" picker: every year with a
/// recorded visit, newest first, minus the two the segmented control already
/// shows as buttons.
///
/// Only years that actually have visits (`OrgStatistics.visitYears`) — a fixed
/// "last ten years" range would invite reporting on a year the group did not
/// exist. A gap year is likewise not offered: there is nothing in it to report.
List<int> earlierReportYears(List<int> visitYears, DateTime now) {
  final shown = {now.year, now.year - 1};
  return [
    for (final year in visitYears)
      if (!shown.contains(year)) year,
  ];
}

/// The reporting period: the two most recent years, any earlier year with
/// visits, or all time.
///
/// ONE control, shared by the statistics screen and the export sheet. The two
/// have to agree on what "2026" means — they read the same routes with the same
/// `?year=`, and somebody who has just read a year's figures and taps
/// "exportieren" is asking for that year's report — so they must not be two
/// controls that merely look alike.
///
/// The month sits UNDER the year rather than beside it, because it narrows the
/// year rather than competing with it — and it disappears entirely for "all
/// time", where a month would name no period at all.
class PeriodSelector extends StatelessWidget {
  const PeriodSelector({
    required this.selected,
    required this.visitYears,
    required this.onChanged,
    this.now,
    this.enabled = true,
    super.key,
  });

  final StatsPeriod selected;

  /// Every year with a recorded visit, newest first — off the statistics
  /// payload, which is org-wide regardless of the period being shown.
  final List<int> visitYears;

  final ValueChanged<StatsPeriod> onChanged;

  /// Frozen by the caller so the labels and the year actually sent do not shift
  /// if the screen happens to be open across midnight on New Year's Eve.
  final DateTime? now;

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final today = now ?? DateTime.now();
    final earlier = earlierReportYears(visitYears, today);
    final year = selected.year;
    final picked = year != null && year != today.year && year != today.year - 1
        ? year
        : null;
    // MaterialLocalizations has no bare month-name format, and slicing one out
    // of a full date would depend on the locale's field order.
    final monthName = DateFormat.MMMM(
      Localizations.localeOf(context).toString(),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Labelled with the years themselves rather than "dieses"/"letztes": in
        // January the difference matters, and a concrete number leaves nothing
        // to work out.
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<int?>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: today.year, label: Text('${today.year}')),
              ButtonSegment(
                value: today.year - 1,
                label: Text('${today.year - 1}'),
              ),
              if (picked != null)
                ButtonSegment(value: picked, label: Text('$picked')),
              ButtonSegment(value: null, label: Text(l10n.statsPeriodAllTime)),
            ],
            selected: {year},
            onSelectionChanged: enabled
                ? (s) => onChanged(selected.withYear(s.single))
                : null,
          ),
        ),
        if (!selected.isAllTime) ...[
          const SizedBox(height: ZugvogelSpacing.sm),
          // A dropdown rather than twelve more segments: the month is a
          // refinement of the year above it, and twelve buttons would outweigh
          // the period they narrow.
          Align(
            alignment: Alignment.centerLeft,
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int?>(
                value: selected.month,
                isDense: true,
                onChanged: enabled
                    ? (month) => onChanged(selected.withMonth(month))
                    : null,
                items: [
                  DropdownMenuItem(child: Text(l10n.statsPeriodWholeYear)),
                  for (var m = 1; m <= 12; m++)
                    DropdownMenuItem(
                      value: m,
                      child: Text(monthName.format(DateTime(2000, m))),
                    ),
                ],
              ),
            ),
          ),
        ],
        if (earlier.isNotEmpty) ...[
          const SizedBox(height: ZugvogelSpacing.xs),
          Align(
            alignment: Alignment.centerLeft,
            child: PopupMenuButton<int>(
              enabled: enabled,
              // Selecting from the picker also selects the period: opening the
              // menu to choose a year and then having to press the resulting
              // button as well would be a second step for a decision already
              // made.
              onSelected: (year) => onChanged(selected.withYear(year)),
              itemBuilder: (context) => [
                for (final year in earlier)
                  PopupMenuItem(value: year, child: Text('$year')),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: ZugvogelSpacing.sm,
                  vertical: ZugvogelSpacing.xs,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.statsPeriodEarlierYears,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    Icon(
                      Icons.arrow_drop_down,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
