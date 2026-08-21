import 'dart:io';

import 'package:eiermann_models/eiermann_models.dart';
import 'package:test/test.dart';

/// Where the hook lives, found by walking up from wherever the runner started.
///
/// `dart test` in the package and `flutter test` from the repo root disagree
/// about the working directory, and hard-coding either produces a test that
/// passes on one machine by not running.
File _hookFile() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 6; i++) {
    final candidate = File(
      '${dir.path}/backend/pocketbase/pb_hooks/app_spot_phase.js',
    );
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    'app_spot_phase.js not found above ${Directory.current.path}. This test '
    'exists to compare the two graphs; skipping when it cannot find one would '
    'make it a test that passes by not running.',
  );
}

/// Reads `const ALLOWED = {...}` out of the hook as wire strings.
Map<String, List<String>> _hookGraph(String source) {
  final block = RegExp(
    r'const ALLOWED = \{(.*?)\};',
    dotAll: true,
  ).firstMatch(source);
  expect(
    block,
    isNotNull,
    reason:
        'the hook no longer declares `const ALLOWED = {...}`. If the graph '
        'moved, move this test with it rather than deleting it.',
  );
  final entries = RegExp(
    r'(\w+):\s*\[([^\]]*)\]',
  ).allMatches(block!.group(1)!);
  return {
    for (final entry in entries)
      entry.group(1)!: RegExp('"([^"]+)"')
          .allMatches(entry.group(2)!)
          .map((m) => m.group(1)!)
          .toList(),
  };
}

void main() {
  group('the phase graph', () {
    // WHY this test exists rather than a comment asking people to keep the two
    // in step: the client copy decides which moves the dossier offers, and a
    // divergence has no symptom on either side alone. Too generous and the user
    // gets a button that only ever produces an error; too strict and a move the
    // server allows becomes unreachable, with nothing anywhere saying so.
    late Map<String, List<String>> hook;

    setUpAll(() => hook = _hookGraph(_hookFile().readAsStringSync()));

    test('matches app_spot_phase.js exactly', () {
      final dart = {
        for (final entry in spotPhaseTransitions.entries)
          entry.key.wire: entry.value.map((phase) => phase.wire).toList(),
      };
      expect(
        dart,
        hook,
        reason:
            'the client offers a different set of moves than the server '
            'accepts',
      );
    });

    test('names every phase this build knows', () {
      // A phase with no entry would silently offer nothing, which reads as
      // "this Spot is stuck" rather than as a missing rule.
      expect(
        spotPhaseTransitions.keys.toSet(),
        SpotPhase.values.toSet(),
        reason: 'every phase needs a row, even if the row is empty',
      );
    });

    test('leads nowhere the phase list cannot name', () {
      for (final targets in spotPhaseTransitions.values) {
        for (final target in targets) {
          expect(SpotPhase.values, contains(target));
        }
      }
    });

    test('never offers the phase a Spot is already in', () {
      // A menu entry that changes nothing would still write, still touch
      // `updated`, and still look like something happened.
      for (final entry in spotPhaseTransitions.entries) {
        expect(entry.value, isNot(contains(entry.key)));
      }
    });
  });

  group('what a move has to collect', () {
    const base = Spot(id: 's1', name: 'Bahnhofstraße 12');

    test('an unknown phase offers no move at all', () {
      // The server gained a fifth phase. Guessing which moves it permits means
      // offering a refusal.
      expect(base.allowedPhases, isEmpty);
    });

    test('a refused Erkundung closes without naming a reason', () {
      final refused = base.copyWith(
        phase: SpotPhase.prospect,
        prospectStage: ProspectStage.refused,
      );
      expect(refused.closingNeedsReason, isFalse);
    });

    test('every other closing needs one', () {
      for (final phase in [
        SpotPhase.prospect,
        SpotPhase.active,
        SpotPhase.paused,
      ]) {
        for (final stage in [
          null,
          ProspectStage.untouched,
          ProspectStage.tenantSpoken,
          ProspectStage.ownerSpoken,
          ProspectStage.permitted,
        ]) {
          final spot = base.copyWith(phase: phase, prospectStage: stage);
          expect(
            spot.closingNeedsReason,
            isTrue,
            reason: 'phase $phase, stage $stage',
          );
        }
      }
      // An ACTIVE Spot whose funnel says "refused" still needs a reason: it was
      // entered, so something changed since, and the refusal is not that thing.
      expect(
        base
            .copyWith(
              phase: SpotPhase.active,
              prospectStage: ProspectStage.refused,
            )
            .closingNeedsReason,
        isTrue,
      );
    });

    test('activating an Erkundung records the Zusage unless it is there', () {
      final permitted = base.copyWith(
        phase: SpotPhase.prospect,
        prospectStage: ProspectStage.permitted,
      );
      expect(permitted.activationRecordsConsent, isFalse);

      for (final stage in [
        null,
        ProspectStage.untouched,
        ProspectStage.tenantSpoken,
        ProspectStage.ownerSpoken,
        ProspectStage.refused,
      ]) {
        expect(
          base
              .copyWith(phase: SpotPhase.prospect, prospectStage: stage)
              .activationRecordsConsent,
          isTrue,
          reason: 'stage $stage',
        );
      }
    });

    test('reopening a closed Spot records nothing', () {
      // The gate is on `prospect -> active` only, and reopening leaves the
      // Erkundung history exactly as it was.
      final closed = base.copyWith(
        phase: SpotPhase.closed,
        prospectStage: ProspectStage.refused,
        closedReason: ClosedReason.netted,
      );
      expect(closed.activationRecordsConsent, isFalse);
      expect(closed.allowedPhases, [SpotPhase.active]);
    });
  });
}
