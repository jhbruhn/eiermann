import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_data/zugvogel_data.dart'
    show RepositoryErrorKind, RepositoryException;

/// Which rendering of the period report to fetch.
///
/// One route serves all three (`GET /api/eiermann/reports/period`), because
/// they are three renderings of ONE report over one row set — not three
/// features. The `wire` value is the `?format=` the server branches on, so
/// renaming the Dart identifier cannot change what is asked for.
enum ReportFormat {
  /// The Behördenbericht: every visit, grouped by address. What a permission is
  /// renewed on.
  authority('pdf', 'pdf', 'application/pdf'),

  /// The Förderer-Zusammenfassung: the same period without the per-visit
  /// detail. What a funding is argued with.
  summary('summary', 'pdf', 'application/pdf'),

  /// The same table as a spreadsheet. Encoded SERVER-side, deliberately: a
  /// client-side CSV writer is a second definition of the same table, and the
  /// two would word a cell differently the first time either was touched.
  csv('csv', 'csv', 'text/csv');

  const ReportFormat(this.wire, this.extension, this.mimeType);

  /// The `?format=` value the route branches on.
  final String wire;

  /// The file extension a share sheet should offer.
  final String extension;

  final String mimeType;
}

/// Fetches a rendered period report as BYTES.
///
/// Its own repository rather than a method on `StatsRepository`: this one
/// reads a file, and the difference is not cosmetic — it goes through an HTTP
/// client rather than the PocketBase SDK (which decodes every response as JSON
/// and would corrupt a PDF), and it needs a timeout measured in minutes rather
/// than seconds, because a Typst compile over a year of visits is a subprocess
/// on the server.
class ReportsRepository {
  ReportsRepository(
    this.pb, {
    http.Client? httpClient,
    this.networkTimeout = const Duration(minutes: 2),
  }) : _httpClient = httpClient ?? http.Client();

  final PocketBase pb;
  final http.Client _httpClient;

  /// Generous on purpose: the server renders a PDF in a subprocess over every
  /// visit of the period. A minute-scale ceiling is still a ceiling — without
  /// one a stalled request leaves a spinner nobody can clear.
  final Duration networkTimeout;

  /// The report for [year] (null = every visit on record), optionally narrowed
  /// to one [month].
  ///
  /// [lang] is the app's OWN UI language, so the document comes out in the
  /// language the person asking for it is reading. [tzOffsetMinutes] is this
  /// device's UTC offset — the same value the statistics screen sends, which is
  /// what makes the exported file and the figures on screen agree about what a
  /// year is.
  Future<Uint8List> fetch({
    required ReportFormat format,
    int? year,
    int? month,
    String lang = 'de',
    int? tzOffsetMinutes,
  }) => _guard(() async {
    final uri = pb.buildURL('/api/eiermann/reports/period', {
      if (year != null) 'year': '$year',
      if (year != null && month != null) 'month': '$month',
      'format': format.wire,
      'lang': lang,
      if (tzOffsetMinutes != null) 'tzOffsetMinutes': '$tzOffsetMinutes',
    });
    final response = await _httpClient.get(
      uri,
      headers: {
        if (pb.authStore.isValid) 'Authorization': pb.authStore.token,
      },
    );
    if (response.statusCode != 200) {
      // Through the same translation as every other failure, so the UI's error
      // copy does not need a second vocabulary for this one call.
      throw RepositoryException.fromClient(
        ClientException(url: uri, statusCode: response.statusCode),
      );
    }
    return response.bodyBytes;
  });

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
