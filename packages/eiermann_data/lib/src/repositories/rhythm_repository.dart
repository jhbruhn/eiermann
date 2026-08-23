import 'dart:async';

import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_data/zugvogel_data.dart'
    show RepositoryErrorKind, RepositoryException;

/// The org's rhythm numbers, off `GET|PATCH /api/eiermann/rhythm`.
///
/// **Not a `PbRepository`, and specifically not a repository over
/// `organisations`.** The numbers live in that table's `settings` JSON field,
/// and reading them from here would be mapping a JSON field a second time —
/// the trap that left two federfall features silently inert. A JSON value the
/// client fails to parse does not error, it falls into a default, and the app
/// then works correctly with numbers nobody chose.
///
/// So the server decodes once (`zv_org.js`) and answers in types, and
/// `organisations.updateRule` stays null: this route is the only door to these
/// five fields, and it validates each of them.
///
/// A single concrete class rather than an interface plus a `Pb`-prefixed
/// implementation — mock it directly in tests, as with `StatsRepository`.
class RhythmRepository {
  RhythmRepository(
    this.pb, {
    this.networkTimeout = const Duration(seconds: 15),
  });

  final PocketBase pb;
  final Duration networkTimeout;

  /// What the rhythm is currently using.
  ///
  /// Readable by every member, not just the coordination: somebody looking at
  /// "in 14 Tagen" needs to know whether that is the base interval or a
  /// stretched one, and the due explanation cannot say so without these.
  Future<RhythmSettings> fetch() => _guard(() async {
    final response = await pb.send<Map<String, dynamic>>(
      '/api/eiermann/rhythm',
    );
    return RhythmSettings.fromResponse(response);
  });

  /// Writes the numbers, and returns what the rhythm will ACTUALLY use.
  ///
  /// The answer is the server's read-back, never an echo of [settings]: a value
  /// the server normalised has to reach the screen as the server sees it, or
  /// the form goes on showing what it typed while the ladder uses something
  /// else — which is the exact failure this whole route exists to prevent.
  ///
  /// Refuses with a code the client maps (`rhythm_steps_below_base` and the
  /// rest), because the server does not know which language the reader speaks.
  Future<RhythmSettings> save(RhythmSettings settings) => _guard(() async {
    final response = await pb.send<Map<String, dynamic>>(
      '/api/eiermann/rhythm',
      method: 'PATCH',
      body: settings.toBody(),
    );
    return RhythmSettings.fromResponse(response);
  });

  /// Mirrors `PbRepository`'s guard: timeout → network, SDK errors →
  /// [RepositoryException], anything else wrapped so the UI error states get a
  /// stable type.
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
