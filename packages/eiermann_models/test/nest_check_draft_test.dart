import 'dart:io';

import 'package:eiermann_models/eiermann_models.dart';
import 'package:test/test.dart';

/// The hook this arithmetic is a copy of, found by walking up from wherever the
/// runner started — `dart test` in the package and `flutter test` from the repo
/// root disagree about the working directory, and hard-coding either produces a
/// test that passes on one machine by not running.
File _hookFile() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 6; i++) {
    final candidate = File(
      '${dir.path}/backend/pocketbase/pb_hooks/app_visit.js',
    );
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    'app_visit.js not found above ${Directory.current.path}. This test exists '
    'to hold two copies of one arithmetic together; skipping when it cannot '
    'find one would make it a test that passes by not running.',
  );
}

NestCheckDraft draft({
  CheckState state = CheckState.swapped,
  int realBefore = 0,
  int dummyBefore = 0,
  int removedReal = 0,
  int addedDummy = 0,
  String? note,
  String? speciesLabel,
}) => NestCheckDraft(
  nest: 'n1',
  nestLabel: 'N1',
  state: state,
  realBefore: realBefore,
  dummyBefore: dummyBefore,
  removedReal: removedReal,
  addedDummy: addedDummy,
  note: note,
  speciesLabel: speciesLabel,
);

void main() {
  group('the check arithmetic', () {
    test('a clean swap leaves dummies and no real egg', () {
      final check = draft(
        realBefore: 2,
        removedReal: 2,
        addedDummy: 2,
      );

      expect(check.realAfter, 0);
      expect(check.dummyAfter, 2);
      expect(check.effectiveState, CheckState.swapped);
      expect(check.isHalfClutch, isFalse);
    });

    test(
      'a real egg left behind IS the Halbgelege, whatever was asked for',
      () {
        // The client called it `swapped`; the numbers say otherwise, and the
        // Nachkontrolle that keeps a half clutch from hatching unnoticed hangs
        // off exactly this. So it is derived, never believed.
        final check = draft(realBefore: 2, removedReal: 1, addedDummy: 1);

        expect(check.realAfter, 1);
        expect(check.effectiveState, CheckState.partial);
        expect(check.isHalfClutch, isTrue);
      },
    );

    test('a state that does not touch eggs carries no numbers', () {
      final check = draft(
        state: CheckState.untouched,
        realBefore: 2,
        dummyBefore: 1,
      );

      expect(check.touchesEggs, isFalse);
      expect(check.effectiveState, CheckState.untouched);
      expect(check.toBody().containsKey('real_before'), isFalse);
    });

    test('removing more than was there is incoherent', () {
      // The form cannot produce this — a row cannot remove an egg it does not
      // hold — so the flow refuses to send rather than collecting the server's
      // `visit_eggs_removed_exceed_present`.
      expect(draft(realBefore: 1, removedReal: 2).isCoherent, isFalse);
      expect(draft(realBefore: 2, removedReal: 2).isCoherent, isTrue);
    });

    test('the body sends the after-counts so the server can DISAGREE', () {
      // Not because the server needs them: it recomputes them and refuses a
      // body whose own numbers differ. A mismatch means the two sides disagree
      // about what just happened, which is worth a 400 rather than a silent
      // overwrite.
      final body = draft(
        realBefore: 2,
        dummyBefore: 1,
        removedReal: 1,
        addedDummy: 1,
      ).toBody();

      expect(body['real_after'], 1);
      expect(body['dummy_after'], 2);
      // The state sent is the RECONCILED one, so both sides agree about the
      // Halbgelege before the answer comes back.
      expect(body['state'], CheckState.partial.wire);
    });

    test(
      'a species label rides along only when reporting a protected bird',
      () {
        expect(
          draft(
            state: CheckState.protected,
            speciesLabel: 'Dohle',
          ).toBody()['species_label'],
          'Dohle',
        );
        // On any other state it would be an edit to the nest that nobody asked
        // for: the endpoint only moves a nest to `protected` for a `protected`
        // check.
        expect(
          draft(state: CheckState.empty, speciesLabel: 'Dohle').toBody(),
          isNot(contains('species_label')),
        );
      },
    );

    test('an empty note is left out, not sent as an empty string', () {
      expect(draft(note: '').toBody(), isNot(contains('note')));
      expect(draft(note: 'Regen').toBody()['note'], 'Regen');
    });
  });

  group('the hook it mirrors', () {
    late String hook;

    setUpAll(() => hook = _hookFile().readAsStringSync());

    // WHY these are text assertions and not behaviour: the authority is
    // JavaScript running inside PocketBase's JSVM, which a Dart test cannot
    // execute. What it CAN do is fail the moment somebody edits the rule on the
    // server side, which is the drift that has no symptom otherwise — the
    // client would keep predicting the old outcome, the server would store the
    // new one, and every individual screen would look plausible.
    test('still derives partial from real_after, not from the request', () {
      expect(
        hook,
        contains('numbers.real_after > 0 ? "partial" : "swapped"'),
        reason:
            'reconcileState changed. NestCheckDraftMath.effectiveState is the '
            'client copy of exactly this line — move both or neither.',
      );
    });

    test('still computes the after-counts the same way', () {
      expect(hook, contains('const realAfter = realBefore - removedReal;'));
      expect(hook, contains('const dummyAfter = dummyBefore + addedDummy;'));
      expect(
        hook,
        contains('removedReal > realBefore'),
        reason:
            'the one refusal the client pre-empts through '
            'NestCheckDraftMath.isCoherent',
      );
    });

    test('still zeroes the counts for a state that does not touch eggs', () {
      // The client's `toBody` leaves them out entirely, which is the same thing
      // to the endpoint and one fewer place to get a number wrong.
      expect(
        hook,
        contains(
          'const touchesEggs = state === "swapped" || state === "partial"',
        ),
      );
    });
  });
}
