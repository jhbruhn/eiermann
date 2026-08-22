import 'dart:async';

import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_data/zugvogel_data.dart'
    show RepositoryErrorKind, RepositoryException;

/// The org's reporting figures off `GET /api/eiermann/stats`.
///
/// Not a `PbRepository`: there is no collection behind this. The screen used
/// to be conceivable as a client-side aggregation over `visits` +
/// `nest_checks` + `findings`, and that shape is wrong twice — it pulls a
/// monthly series with a comparison year behind it onto a handset, and it puts
/// a second definition of every figure in the app, one that will disagree with
/// the printed report the first time either side is touched.
///
/// A single-method class rather than the usual interface + `Pb`-prefixed impl
/// split: one member would only trip the `one_member_abstracts` lint. Mock this
/// concrete class directly in tests.
class StatsRepository {
  StatsRepository(this.pb, {this.networkTimeout = const Duration(seconds: 30)});

  final PocketBase pb;

  /// Longer than a plain collection read: the server aggregates the org's whole
  /// visit history to build the comparison series.
  final Duration networkTimeout;

  /// The figures for [year] (null = every visit on record), optionally narrowed
  /// to one [month] of it.
  ///
  /// [tzOffsetMinutes] is this device's own UTC offset
  /// (`DateTime.now().timeZoneOffset.inMinutes`). The server has no timezone
  /// database to resolve a zone NAME against, so it asks the caller to state
  /// its offset rather than guessing — and that offset is what decides which
  /// side of New Year a late-evening visit falls on. Passing it is what makes
  /// this screen and the printed report agree about what a year is.
  Future<OrgStatistics> fetch({
    int? year,
    int? month,
    int? tzOffsetMinutes,
  }) => _guard(() async {
    final response = await pb.send<Map<String, dynamic>>(
      '/api/eiermann/stats',
      query: {
        if (year != null) 'year': '$year',
        // A month without a year names no period; the route refuses that, so it
        // is never sent on its own.
        if (year != null && month != null) 'month': '$month',
        if (tzOffsetMinutes != null) 'tzOffsetMinutes': '$tzOffsetMinutes',
      },
    );
    return OrgStatistics.fromResponse(response);
  });

  /// Mirrors `PbRepository`'s guard: timeout → network, SDK errors →
  /// [RepositoryException], anything else (an unexpected response shape, say)
  /// wrapped so the UI error states get a stable type.
  Future<R> _guard<R>(Future<R> Function() op) async {
    try {
      return await op().timeout(networkTimeout);
    } on TimeoutException {
      throw const RepositoryException(
        'Could not reach the server',
        kind: RepositoryErrorKind.network,
      );
    } on ClientException catch (e) {
      throw RepositoryException.fromClient(e);
    } on RepositoryException {
      rethrow;
    } on Object catch (e) {
      throw RepositoryException('Unexpected repository failure: $e', cause: e);
    }
  }
}
