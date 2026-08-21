import 'dart:async';

import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_data/zugvogel_data.dart';

/// The whole Besuch, in one request: `POST /api/eiermann/visit`.
///
/// Not a [PbRepository], and the type says why: `visits`, `nest_checks` and
/// `nest_eggs` have no create rule at all. There is no per-record path to
/// writing a visit, deliberately — if the connection broke after the second
/// nest, the database would hold a visit in which five nests were not checked,
/// and that is indistinguishable from five nests somebody chose not to touch.
/// So the endpoint takes the whole body and writes it in one transaction.
///
/// The [submit] contract is the other half of the online-only decision: the
/// form holds everything in memory, exactly one call can fail, and the
/// Idempotency-Key makes the retry safe to press three times.
class VisitsRepository {
  VisitsRepository(
    this.pb, {
    this.networkTimeout = const Duration(seconds: 30),
  });

  final PocketBase pb;

  /// Caps one submit. Longer than a collection write: this is one transaction
  /// over a visit, its checks, the egg rewrite and the rhythm — and a volunteer
  /// on a stairwell connection has nothing else to do while it runs.
  final Duration networkTimeout;

  static const _route = '/api/eiermann/visit';

  /// Writes [draft] and returns what the endpoint stored.
  ///
  /// [idempotencyKey] must be generated ONCE per visit — when the user first
  /// presses "fertig" — and reused for every retry of that same visit. The
  /// server stores the response under it and replays it instead of writing a
  /// second visit. A fresh key per attempt would turn "press it three times"
  /// into three visits, three sets of checks and a rhythm advanced three times:
  /// exactly the damage the retry exists to avoid.
  ///
  /// Reusing one key for a DIFFERENT body is refused with
  /// `visit_idempotency_key_reused` — a 409, not a replay, because answering
  /// with the first visit's result would mean the second one is never written
  /// while the app reports success.
  Future<VisitResult> submit(
    VisitDraft draft, {
    required String idempotencyKey,
  }) => _guard(() async {
    final response = await pb.send<Map<String, dynamic>>(
      _route,
      method: 'POST',
      body: draft.toBody(),
      headers: {'Idempotency-Key': idempotencyKey},
    );
    return VisitResult.fromResponse(response);
  });

  /// The classification [PbRepository.guard] applies, for a call that is not
  /// against a collection — plus the one thing this route needs and that one
  /// does not.
  ///
  /// **A timeout is `unknownOutcome`, never `network`.** `Future.timeout`
  /// abandons the request on this side but cannot cancel it, so a slow server
  /// may still have committed the visit. The UI must therefore not say "not
  /// reached, try again" — it says the outcome is unknown and offers the retry,
  /// which is safe because the key is the same.
  ///
  /// **A 409 carries a code.** `RepositoryException.fromClient` reads refusal
  /// codes only out of the validation statuses, and the key-reuse refusal is a
  /// 409 — so it would arrive with no code and the client would show generic
  /// copy for the one failure that means the app has a bug. Read here instead
  /// of widened over there: adding a kind to the shared enum breaks every
  /// exhaustive switch in both apps. Moving it into zugvogel is the neighbour
  /// of `eiermann-a0v`, filed separately.
  Future<R> _guard<R>(Future<R> Function() op) async {
    try {
      return await op().timeout(networkTimeout);
    } on TimeoutException {
      throw const RepositoryException(
        'The server did not respond in time — the visit may or may not have '
        'been written',
        kind: RepositoryErrorKind.unknownOutcome,
      );
    } on ClientException catch (e) {
      if (e.statusCode == 409) {
        final data = e.response['data'];
        throw RepositoryException(
          'Idempotency key reused with a different body',
          kind: RepositoryErrorKind.validation,
          statusCode: 409,
          cause: e,
          serverCodes: data is Map
              ? data.keys.map((key) => key.toString()).toList(growable: false)
              : const <String>[],
        );
      }
      throw RepositoryException.fromClient(e);
    } on RepositoryException {
      rethrow;
    } on Object catch (e) {
      throw RepositoryException('Unexpected repository failure: $e', cause: e);
    }
  }
}
