import 'dart:async';

import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

class _MockPb extends Mock implements PocketBase {}

const _route = '/api/eiermann/visit';

VisitDraft _draft() => const VisitDraft(
  spot: 's1',
  outcome: VisitOutcome.checked,
  checks: [
    NestCheckDraft(
      nest: 'n1',
      nestLabel: 'N1',
      state: CheckState.swapped,
      realBefore: 2,
      removedReal: 2,
      addedDummy: 2,
    ),
  ],
);

void main() {
  late _MockPb pb;

  setUp(() {
    pb = _MockPb();
    registerFallbackValue(<String, dynamic>{});
  });

  void answers(Map<String, dynamic> body) {
    when(
      () => pb.send<Map<String, dynamic>>(
        _route,
        method: any(named: 'method'),
        body: any(named: 'body'),
        headers: any(named: 'headers'),
      ),
    ).thenAnswer((_) async => body);
  }

  /// Makes the route throw [error]. `only_throw_errors` is off for this helper
  /// on purpose: a `ClientException` is exactly what the SDK throws, and the
  /// point of the test is what the repository does with one.
  void fails(Object error) {
    when(
      () => pb.send<Map<String, dynamic>>(
        _route,
        method: any(named: 'method'),
        body: any(named: 'body'),
        headers: any(named: 'headers'),
      ),
      // A ClientException is exactly what the SDK throws, and what this
      // repository has to translate — so the test has to be able to throw one.
      // ignore: only_throw_errors
    ).thenAnswer((_) async => throw error);
  }

  /// The captured arguments of the one call, as maps.
  ///
  /// Read untyped and looked up by content rather than by position: mocktail
  /// returns one flat list of captures, and asserting on an index makes the
  /// test depend on the order the named arguments happen to appear in.
  ({Map<Object?, Object?> body, Map<Object?, Object?> headers}) sent() {
    final captured = verify(
      () => pb.send<Map<String, dynamic>>(
        _route,
        method: captureAny(named: 'method'),
        body: captureAny(named: 'body'),
        headers: captureAny(named: 'headers'),
      ),
    ).captured;
    final maps = captured.whereType<Map<Object?, Object?>>().toList();
    return (
      body: maps.firstWhere((map) => map.containsKey('spot')),
      headers: maps.firstWhere((map) => map.containsKey('Idempotency-Key')),
    );
  }

  test('posts the whole visit to the ONE route that can write it', () async {
    // `visits`, `nest_checks` and `nest_eggs` have no create rule at all. There
    // is deliberately no per-record path: a visit assembled from seven writes
    // that breaks after the second leaves a visit in which five nests were not
    // checked, and that is indistinguishable from five nests somebody chose not
    // to touch.
    answers({'visit': 'v1', 'checks': <Object>[]});

    await VisitsRepository(pb).submit(_draft(), idempotencyKey: 'k1');

    final call = sent();
    expect(call.body['spot'], 's1');
    expect((call.body['checks']! as List).length, 1);
  });

  test(
    'carries the Idempotency-Key, which is what makes a retry safe',
    () async {
      answers({'visit': 'v1', 'checks': <Object>[]});

      await VisitsRepository(pb).submit(_draft(), idempotencyKey: 'same-key');

      expect(sent().headers['Idempotency-Key'], 'same-key');
    },
  );

  test('reads the states the server decided on, not the ones sent', () async {
    // The server has the last word on the Halbgelege: it derives `partial` from
    // the arithmetic, and the Nachkontrolle hangs off that.
    answers({
      'visit': 'v1',
      'checks': [
        {'id': 'c1', 'nest': 'n1', 'state': 'partial'},
      ],
    });

    final result = await VisitsRepository(pb).submit(
      _draft(),
      idempotencyKey: 'k1',
    );

    expect(result.halfClutches.map((check) => check.nest), ['n1']);
  });

  test('a timeout is unknownOutcome, NEVER network', () async {
    // `Future.timeout` abandons the request on this side but cannot cancel it,
    // so the visit may still be written. Telling the user "not reached, try
    // again" over a write that may have landed is the one thing this must not
    // do — and the retry is still right, because the key makes it safe.
    when(
      () => pb.send<Map<String, dynamic>>(
        _route,
        method: any(named: 'method'),
        body: any(named: 'body'),
        headers: any(named: 'headers'),
      ),
    ).thenAnswer((_) => Future.delayed(const Duration(seconds: 5), () => {}));

    final repo = VisitsRepository(
      pb,
      networkTimeout: const Duration(milliseconds: 10),
    );

    await expectLater(
      repo.submit(_draft(), idempotencyKey: 'k1'),
      throwsA(
        isA<RepositoryException>().having(
          (e) => e.kind,
          'kind',
          RepositoryErrorKind.unknownOutcome,
        ),
      ),
    );
  });

  test('a 409 keeps its refusal code, so the client can name it', () async {
    // The key-reuse refusal is a 409, and `RepositoryException.fromClient`
    // reads codes only out of the validation statuses — so without this the one
    // failure that means the app has a bug would arrive as generic copy.
    fails(
      ClientException(
        statusCode: 409,
        response: {
          'data': {'visit_idempotency_key_reused': 1},
        },
      ),
    );

    await expectLater(
      VisitsRepository(pb).submit(_draft(), idempotencyKey: 'k1'),
      throwsA(
        isA<RepositoryException>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having(
              (e) => e.serverCodes,
              'serverCodes',
              contains('visit_idempotency_key_reused'),
            ),
      ),
    );
  });

  test('any other refusal keeps its own code too', () async {
    fails(
      ClientException(
        statusCode: 400,
        response: {
          'data': {'nest_protected_no_egg_changes': 1},
        },
      ),
    );

    await expectLater(
      VisitsRepository(pb).submit(_draft(), idempotencyKey: 'k1'),
      throwsA(
        isA<RepositoryException>().having(
          (e) => e.serverCodes,
          'serverCodes',
          contains('nest_protected_no_egg_changes'),
        ),
      ),
    );
  });

  test('an unexpected error still surfaces as a RepositoryException', () async {
    // Every screen in this app branches on that type. A raw TypeError out of a
    // parser would reach the user as a red screen instead of the app's error
    // copy.
    fails(StateError('nope'));

    await expectLater(
      VisitsRepository(pb).submit(_draft(), idempotencyKey: 'k1'),
      throwsA(isA<RepositoryException>()),
    );
  });
}
