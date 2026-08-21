import 'package:eiermann_models/eiermann_models.dart';
import 'package:test/test.dart';

NestCheckDraft _swap(String nest, {int real = 2}) => NestCheckDraft(
  nest: nest,
  nestLabel: nest.toUpperCase(),
  state: CheckState.swapped,
  realBefore: real,
  removedReal: real,
  addedDummy: real,
);

void main() {
  group('the visit body', () {
    test('carries every check in ONE body', () {
      // The whole point: seven REST writes that break after the second leave a
      // visit in which five nests were not checked, and that is
      // indistinguishable from five nests somebody chose not to touch.
      final draft = VisitDraft(
        spot: 's1',
        outcome: VisitOutcome.checked,
        checks: [_swap('n1'), _swap('n2', real: 1)],
      );

      final body = draft.toBody();
      expect(body['spot'], 's1');
      expect(body['outcome'], 'checked');
      expect((body['checks'] as List).length, 2);
      expect(draft.removedReal, 3);
      expect(draft.addedDummy, 3);
    });

    test('a skipped visit sends its reason and no checks', () {
      final body = const VisitDraft(
        spot: 's1',
        outcome: VisitOutcome.skipped,
        skipReason: SkipReason.noKey,
        skipNote: 'Kaya im Urlaub',
      ).toBody();

      expect(body['skip_reason'], 'no_key');
      expect(body['skip_note'], 'Kaya im Urlaub');
      expect(body['checks'], isEmpty);
    });

    test('a skip with no reason is not sendable', () {
      // Refused in the form rather than by the server, for the same reason the
      // server refuses it: the record could not say whether anybody tried.
      expect(
        const VisitDraft(
          spot: 's1',
          outcome: VisitOutcome.skipped,
        ).isSendable,
        isFalse,
      );
      expect(
        const VisitDraft(
          spot: 's1',
          outcome: VisitOutcome.skipped,
          skipReason: SkipReason.nobodyThere,
        ).isSendable,
        isTrue,
      );
    });

    test('a skip that somehow carries checks is not sendable either', () {
      // The endpoint refuses it, and the reason is worth keeping on this side
      // too: a check inside a non-event is an observation, and the rhythm would
      // advance on a nest nobody saw.
      expect(
        VisitDraft(
          spot: 's1',
          outcome: VisitOutcome.skipped,
          skipReason: SkipReason.noTime,
          checks: [_swap('n1')],
        ).isSendable,
        isFalse,
      );
    });

    test('a visit with no nests at all is still sendable', () {
      // A building with no nests recorded is one nobody has looked at properly.
      // Going there and finding nothing to check is a visit, and the server
      // dates the Spot from it.
      expect(
        const VisitDraft(
          spot: 's1',
          outcome: VisitOutcome.checked,
        ).isSendable,
        isTrue,
      );
    });

    test('incoherent numbers block the send', () {
      expect(
        const VisitDraft(
          spot: 's1',
          outcome: VisitOutcome.checked,
          checks: [
            NestCheckDraft(
              nest: 'n1',
              nestLabel: 'N1',
              state: CheckState.swapped,
              realBefore: 1,
              removedReal: 2,
            ),
          ],
        ).isSendable,
        isFalse,
      );
    });

    test('the half clutches are the ones the arithmetic makes partial', () {
      final draft = VisitDraft(
        spot: 's1',
        outcome: VisitOutcome.checked,
        checks: [
          _swap('n1'),
          const NestCheckDraft(
            nest: 'n2',
            nestLabel: 'N2',
            state: CheckState.swapped,
            realBefore: 2,
            removedReal: 1,
            addedDummy: 1,
          ),
        ],
      );

      expect(draft.halfClutches.map((check) => check.nest), ['n2']);
    });
  });

  group('the endpoint answer', () {
    test('reads the ids and the states the server decided on', () {
      final result = VisitResult.fromResponse({
        'visit': 'v1',
        'checks': [
          {'id': 'c1', 'nest': 'n1', 'state': 'swapped'},
          {'id': 'c2', 'nest': 'n2', 'state': 'partial'},
        ],
      });

      expect(result.visit, 'v1');
      expect(result.halfClutches.map((check) => check.nest), ['n2']);
    });

    test(
      'a state this build has no name for reads as null, not as a known one',
      () {
        final result = VisitResult.fromResponse({
          'visit': 'v1',
          'checks': [
            {'id': 'c1', 'nest': 'n1', 'state': 'brooding'},
          ],
        });

        expect(result.checks.single.state, isNull);
        expect(result.halfClutches, isEmpty);
      },
    );

    test('a malformed answer yields a result rather than throwing', () {
      final result = VisitResult.fromResponse({
        'visit': 'v1',
        'checks': 'nope',
      });

      expect(result.visit, 'v1');
      expect(result.checks, isEmpty);
    });
  });
}
