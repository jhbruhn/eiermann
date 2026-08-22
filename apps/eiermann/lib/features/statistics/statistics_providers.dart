import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'statistics_providers.g.dart';

/// A reporting period: a calendar year, one month of it, or everything on
/// record.
///
/// A [month] without a [year] names no period at all — "März" is not a date —
/// so it can only be set alongside one, which is also what the server enforces
/// (`?month=` requires `?year=`, refused with a code).
@immutable
class StatsPeriod {
  const StatsPeriod({this.year, this.month});

  /// Every visit on record.
  static const allTime = StatsPeriod();

  final int? year;
  final int? month;

  bool get isAllTime => year == null;

  /// Same year, different month (null = the whole year). All time keeps no
  /// month, so switching to it and back cannot leave a stray one behind.
  StatsPeriod withMonth(int? month) =>
      StatsPeriod(year: year, month: year == null ? null : month);

  StatsPeriod withYear(int? year) =>
      StatsPeriod(year: year, month: year == null ? null : month);

  @override
  bool operator ==(Object other) =>
      other is StatsPeriod && other.year == year && other.month == month;

  @override
  int get hashCode => Object.hash(year, month);
}

/// The period the statistics screen is showing. Defaults to the year in
/// progress.
///
/// Held in a provider rather than in the screen's state because the export
/// sheet opens over that screen and must offer the SAME period: somebody who
/// has just read the 2025 figures and taps "exportieren" is asking for the 2025
/// report, not for whatever year a sheet would have defaulted to.
@riverpod
class StatisticsPeriod extends _$StatisticsPeriod {
  @override
  StatsPeriod build() => StatsPeriod(year: DateTime.now().year);

  /// A named action rather than a setter: `select(...)` says what the tap
  /// meant, where an assignment would only say what changed.
  // ignore: use_setters_to_change_properties
  void select(StatsPeriod period) => state = period;
}

/// The org's figures for the period, computed server-side by
/// `pb_hooks/stats.pb.js`.
///
/// The client aggregates NOTHING. Two reasons, and the second is the one that
/// matters: a series with the previous year behind it spans more history than a
/// handset should be pulling, and these are the same rows the printed report
/// reads — so one implementation is the only way the screen and the PDF can be
/// relied on to agree.
///
/// The device's own UTC offset goes with the request: the server has no
/// timezone database, and the offset is what decides whether a New Year's Eve
/// visit counts to the closing year or the opening one — the same question the
/// report asks.
@riverpod
Future<OrgStatistics> statistics(Ref ref, {int? year, int? month}) async {
  final repo = await ref.watch(statsRepositoryProvider.future);
  return repo.fetch(
    year: year,
    month: month,
    tzOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
  );
}
