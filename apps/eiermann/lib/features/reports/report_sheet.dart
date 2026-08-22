import 'dart:async';

import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/statistics/period_selector.dart';
import 'package:eiermann/features/statistics/statistics_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Opens the export sheet: pick a period, then take it as the Behördenbericht,
/// the Förderer-Zusammenfassung, or the CSV of the same table.
Future<void> showReportSheet(BuildContext context) =>
    showAppSheet<void>(context, builder: (_) => const ReportSheet());

/// Period picker plus one button per framing.
///
/// ── Why one sheet and not three actions ────────────────────────────────────
///
/// All three come off ONE server route over ONE row set (`visit_rows`): they
/// are three renderings of the same report, not three features. Three app-bar
/// icons would present them as unrelated exports and invite the question of
/// which one is "the" report.
///
/// ── Why there is no CSV encoder here ───────────────────────────────────────
///
/// The bytes are produced server-side, including the spreadsheet. A client-side
/// encoder would be a second definition of the same table — and its column
/// titles would drift from the PDF's the first time either was touched, which
/// nobody notices until two exports of the same period are compared.
class ReportSheet extends ConsumerStatefulWidget {
  const ReportSheet({super.key});

  @override
  ConsumerState<ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends ConsumerState<ReportSheet> {
  /// Resolved once: the sheet's labels and its default selection must not shift
  /// if it happens to be open across midnight on New Year's Eve, and the year
  /// sent to the server has to be the one the button said.
  late final DateTime _now = DateTime.now();

  /// Seeded from the period the statistics screen behind this sheet is showing
  /// — somebody who has just read the 2025 figures and taps "exportieren" is
  /// asking for the 2025 report. It stays sheet-local from there: exporting a
  /// different year must not quietly re-scope the screen underneath.
  late StatsPeriod _period = ref.read(statisticsPeriodProvider);

  /// Which format is being fetched, so only the tapped button shows a spinner —
  /// and so no two taps can open two share sheets.
  ReportFormat? _busy;

  Future<void> _export(ReportFormat format) async {
    final l10n = context.l10n;
    final strings = EiermannStrings(l10n);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    // Captured before the first await. The document follows the app's OWN UI
    // language, because the person asking for it is the person reading it; and
    // the server has no timezone database, so this device states its offset —
    // which is what decides whether a New Year's Eve visit counts to the
    // closing year or the opening one.
    final lang = Localizations.localeOf(context).languageCode;
    final tzOffsetMinutes = _now.timeZoneOffset.inMinutes;
    final year = _period.year;
    final month = _period.month;
    final filename =
        '${_fileBase(l10n, format, year, month)}.${format.extension}';

    setState(() => _busy = format);
    try {
      final repo = await ref.read(reportsRepositoryProvider.future);
      final bytes = await repo.fetch(
        format: format,
        year: year,
        month: month,
        lang: lang,
        tzOffsetMinutes: tzOffsetMinutes,
      );
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              bytes,
              mimeType: format.mimeType,
              name: filename,
            ),
          ],
          fileNameOverrides: [filename],
        ),
      );
      // The sheet has done its job; leaving it up over the share result reads
      // as if the export were still pending.
      if (navigator.mounted) unawaited(navigator.maybePop());
    } on Object catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(errorMessage(strings, e))));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// The file name, without extension: sortable and unambiguous in a downloads
  /// folder, and naming the period it covers.
  String _fileBase(
    AppLocalizations l10n,
    ReportFormat format,
    int? year,
    int? month,
  ) {
    final period = year == null
        ? l10n.statsExportFileAllTime
        : month == null
        ? '$year'
        : '$year-${month.toString().padLeft(2, '0')}';
    return format == ReportFormat.summary
        ? l10n.statsExportFileSummary(period)
        : l10n.statsExportFileReport(period);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final busy = _busy != null;

    // The years on record come off the statistics the screen behind this sheet
    // has already loaded — org-wide regardless of the period shown, so there is
    // nothing extra to fetch. Until it lands (or if it failed) the two recent
    // years and "all time" still work; only the picker waits.
    final screenPeriod = ref.watch(statisticsPeriodProvider);
    final visitYears =
        ref
            .watch(
              statisticsProvider(
                year: screenPeriod.year,
                month: screenPeriod.month,
              ),
            )
            .value
            ?.visitYears ??
        const <int>[];

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ZugvogelSpacing.lg,
        0,
        ZugvogelSpacing.lg,
        ZugvogelSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.statsExportAction, style: theme.textTheme.titleLarge),
          const SizedBox(height: ZugvogelSpacing.md),
          Text(
            l10n.statsExportPeriod,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: ZugvogelSpacing.sm),
          // The same control the statistics screen uses, so "2026" cannot mean
          // one thing on screen and another in the exported file.
          PeriodSelector(
            selected: _period,
            visitYears: visitYears,
            now: _now,
            enabled: !busy,
            onChanged: (picked) => setState(() => _period = picked),
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          // The authority report first: it is the one with a deadline behind
          // it.
          PrimaryButton(
            label: l10n.statsExportAuthority,
            icon: Icons.description_outlined,
            isLoading: _busy == ReportFormat.authority,
            onPressed: busy ? null : () => _export(ReportFormat.authority),
          ),
          const SizedBox(height: ZugvogelSpacing.xs),
          Text(
            l10n.statsExportAuthorityHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          _SecondaryExport(
            label: l10n.statsExportSummary,
            hint: l10n.statsExportSummaryHint,
            icon: Icons.insights_outlined,
            loading: _busy == ReportFormat.summary,
            onPressed: busy ? null : () => _export(ReportFormat.summary),
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          _SecondaryExport(
            label: l10n.statsExportCsv,
            hint: l10n.statsExportCsvHint,
            icon: Icons.table_view_outlined,
            loading: _busy == ReportFormat.csv,
            onPressed: busy ? null : () => _export(ReportFormat.csv),
          ),
        ],
      ),
    );
  }
}

/// One of the two exports that is not the authority report: a button and the
/// one line that says who it is for.
///
/// The hint is not decoration. Three documents over the same period differ only
/// in their READER, and a sheet that offered three unexplained buttons would
/// leave that to be worked out by trial and error — one download at a time.
class _SecondaryExport extends StatelessWidget {
  const _SecondaryExport({
    required this.label,
    required this.hint,
    required this.icon,
    required this.loading,
    required this.onPressed,
  });

  final String label;
  final String hint;
  final IconData icon;
  final bool loading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          icon: loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(icon),
          label: Text(label),
          onPressed: onPressed,
        ),
        const SizedBox(height: ZugvogelSpacing.xs),
        Text(
          hint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
