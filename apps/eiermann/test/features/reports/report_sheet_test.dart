import 'dart:async';
import 'dart:typed_data';

import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/reports/report_sheet.dart';
import 'package:eiermann/features/statistics/statistics_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/harness.dart';

class _MockReports extends Mock implements ReportsRepository {}

class _MockStats extends Mock implements StatsRepository {}

void main() {
  late AppLocalizations de;
  late _MockReports reports;
  late _MockStats stats;

  setUpAll(() async {
    de = await germanStrings();
    // mocktail needs a stand-in before `any(named: 'format')` can match an
    // enum parameter.
    registerFallbackValue(ReportFormat.authority);
  });

  /// Stubs the fetch with a future that never completes.
  ///
  /// These tests assert what was REQUESTED. Completing it would hand the bytes
  /// to the platform share channel, which a widget test has no implementation
  /// for — the tap then hangs and reads as a broken button.
  void stubPending([Completer<Uint8List>? pending]) {
    when(
      () => reports.fetch(
        format: any(named: 'format'),
        year: any(named: 'year'),
        month: any(named: 'month'),
        lang: any(named: 'lang'),
        tzOffsetMinutes: any(named: 'tzOffsetMinutes'),
      ),
    ).thenAnswer((_) => (pending ?? Completer<Uint8List>()).future);
  }

  setUp(() {
    reports = _MockReports();
    stats = _MockStats();
    when(
      () => stats.fetch(
        year: any(named: 'year'),
        month: any(named: 'month'),
        tzOffsetMinutes: any(named: 'tzOffsetMinutes'),
      ),
    ).thenAnswer(
      (_) async => const OrgStatistics(visits: 3, visitYears: [2026, 2021]),
    );
    stubPending();
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpApp(
      // The Scaffold stands in for what showAppSheet provides in the app: a
      // Material ancestor (the month dropdown needs one) and somewhere for the
      // failure snackbar to land.
      const Scaffold(body: ReportSheet()),
      overrides: [
        reportsRepositoryProvider.overrideWith((ref) async => reports),
        statsRepositoryProvider.overrideWith((ref) async => stats),
      ],
    );
    await tester.pumpAndSettle();
  }

  testWidgets('all three framings are offered from one sheet', (tester) async {
    // They are three renderings of ONE report over one row set, not three
    // features. Three app-bar icons would invite the question of which one is
    // "the" report.
    await pump(tester);
    expect(find.text(de.statsExportAuthority), findsOneWidget);
    expect(find.text(de.statsExportSummary), findsOneWidget);
    expect(find.text(de.statsExportCsv), findsOneWidget);
  });

  testWidgets('each says who it is for', (tester) async {
    // Three documents over the same period differ only in their READER, and
    // three unexplained buttons would leave that to trial and error — one
    // download at a time.
    await pump(tester);
    expect(find.text(de.statsExportAuthorityHint), findsOneWidget);
    expect(find.text(de.statsExportSummaryHint), findsOneWidget);
    expect(find.text(de.statsExportCsvHint), findsOneWidget);
  });

  testWidgets('the sheet opens on the period the screen was showing', (
    tester,
  ) async {
    // Somebody who has just read the 2021 figures and taps "exportieren" is
    // asking for the 2021 report, not for whatever year a sheet would default
    // to.
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpApp(
      const Scaffold(body: ReportSheet()),
      overrides: [
        reportsRepositoryProvider.overrideWith((ref) async => reports),
        statsRepositoryProvider.overrideWith((ref) async => stats),
        statisticsPeriodProvider.overrideWith(
          () => _FixedPeriod(const StatsPeriod(year: 2021)),
        ),
      ],
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(de.statsExportAuthority));
    await tester.pump();
    verify(
      () => reports.fetch(
        format: ReportFormat.authority,
        year: 2021,
        lang: any(named: 'lang'),
        tzOffsetMinutes: any(named: 'tzOffsetMinutes'),
      ),
    ).called(1);
  });

  testWidgets('the CSV is fetched, never encoded here', (tester) async {
    // A client-side encoder would be a second definition of the same table, and
    // its column titles would drift from the PDF's the first time either was
    // touched.
    await pump(tester);
    await tester.tap(find.text(de.statsExportCsv));
    await tester.pump();
    verify(
      () => reports.fetch(
        format: ReportFormat.csv,
        year: any(named: 'year'),
        month: any(named: 'month'),
        lang: any(named: 'lang'),
        tzOffsetMinutes: any(named: 'tzOffsetMinutes'),
      ),
    ).called(1);
  });

  testWidgets('the document follows the app language and this device offset', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text(de.statsExportSummary));
    await tester.pump();
    final call = verify(
      () => reports.fetch(
        format: ReportFormat.summary,
        year: any(named: 'year'),
        month: any(named: 'month'),
        lang: captureAny(named: 'lang'),
        tzOffsetMinutes: captureAny(named: 'tzOffsetMinutes'),
      ),
    );
    // German, because the harness pumps the app in German — the person asking
    // for the document is the person reading it.
    expect(call.captured[0], 'de');
    // The server has no timezone database, so the caller states its offset.
    expect(call.captured[1], DateTime.now().timeZoneOffset.inMinutes);
  });

  testWidgets('one export at a time, so two taps are not two share sheets', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text(de.statsExportCsv));
    await tester.pump();

    // The tapped button became the spinner; the others keep their labels and
    // lose their tap. A second export mid-flight would open a second share
    // sheet over the first one's result.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text(de.statsExportAuthority), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    for (final button in tester.widgetList<OutlinedButton>(
      find.byType(OutlinedButton),
    )) {
      expect(button.onPressed, isNull);
    }
    // Nor can the period be changed mid-export: the request already named a
    // year, and the file it returns is that year's.
    expect(
      tester
          .widget<SegmentedButton<int?>>(find.byType(SegmentedButton<int?>))
          .onSelectionChanged,
      isNull,
    );
  });

  testWidgets('a failed export reports it and leaves the sheet usable', (
    tester,
  ) async {
    when(
      () => reports.fetch(
        format: any(named: 'format'),
        year: any(named: 'year'),
        month: any(named: 'month'),
        lang: any(named: 'lang'),
        tzOffsetMinutes: any(named: 'tzOffsetMinutes'),
      ),
    ).thenThrow(const RepositoryException('nope'));

    await pump(tester);
    await tester.tap(find.text(de.statsExportAuthority));
    await tester.pumpAndSettle();
    // The sheet stays: a failed render is worth retrying, and closing it would
    // make the reader start the period choice again.
    expect(find.text(de.statsExportAuthority), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
  });
}

/// The screen's period, fixed — so the sheet's seeding can be asserted without
/// driving the control behind it.
class _FixedPeriod extends StatisticsPeriod {
  _FixedPeriod(this._period);

  final StatsPeriod _period;

  @override
  StatsPeriod build() => _period;
}
