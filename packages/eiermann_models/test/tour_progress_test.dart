import 'package:eiermann_models/eiermann_models.dart';
import 'package:test/test.dart';

TourStop _stop(String id, String spot, {int? index, String? name}) =>
    TourStop(id: id, tour: 't1', spot: spot, sortIndex: index, spotName: name);

Visit _visit(
  String id,
  String spot, {
  VisitOutcome outcome = VisitOutcome.checked,
  DateTime? at,
  SkipReason? reason,
  String? spotName,
}) => Visit(
  id: id,
  spot: spot,
  outcome: outcome,
  visitedAt: at,
  skipReason: reason,
  spotName: spotName,
  tourRun: 'r1',
);

void main() {
  group('tourProgress', () {
    test('a route nobody has walked yet is entirely pending', () {
      final progress = tourProgress(
        stops: [_stop('st1', 'a'), _stop('st2', 'b')],
        visits: const [],
      );

      expect(
        progress.entries.map((e) => e.state),
        [TourStopState.pending, TourStopState.pending],
      );
      expect(progress.plannedCount, 2);
      expect(progress.plannedDone, 0);
      expect(progress.isComplete, isFalse);
      expect(progress.nextPending?.spot, 'a');
    });

    test('the template order is kept exactly as given', () {
      // Re-sorting here would be a second opinion about what the route is —
      // the server already sorted by sort_index.
      final progress = tourProgress(
        stops: [_stop('st1', 'c'), _stop('st2', 'a'), _stop('st3', 'b')],
        visits: const [],
      );

      expect(progress.entries.map((e) => e.spot), ['c', 'a', 'b']);
    });

    test('a skipped stop counts as SETTLED, not as outstanding', () {
      // Both are answers to "have we dealt with this building". Treating a skip
      // as unfinished would make a round that ran into three locked doors
      // impossible to complete, and the finish button would be the one thing
      // the screen refuses.
      final progress = tourProgress(
        stops: [_stop('st1', 'a'), _stop('st2', 'b')],
        visits: [
          _visit(
            'v1',
            'a',
            outcome: VisitOutcome.skipped,
            reason: SkipReason.noKey,
          ),
        ],
      );

      final first = progress.entries.first;
      expect(first.state, TourStopState.skipped);
      expect(first.skipReason, SkipReason.noKey);
      expect(first.isDone, isTrue);
      expect(progress.plannedDone, 1);
      expect(progress.nextPending?.spot, 'b');
    });

    test('the latest visit wins when a building was visited twice', () {
      // Somebody is sent away, comes back an hour later with the key. The
      // question a progress list answers is where the building stands NOW —
      // showing the earlier refusal would report the round as less finished
      // than it is.
      final progress = tourProgress(
        stops: [_stop('st1', 'a')],
        visits: [
          _visit(
            'v1',
            'a',
            outcome: VisitOutcome.skipped,
            reason: SkipReason.noKey,
            at: DateTime.utc(2026, 8, 21, 9),
          ),
          _visit('v2', 'a', at: DateTime.utc(2026, 8, 21, 10)),
        ],
      );

      expect(progress.entries.single.state, TourStopState.checked);
      expect(progress.entries.single.visitId, 'v2');
    });

    test('...whatever order the visits arrive in', () {
      final progress = tourProgress(
        stops: [_stop('st1', 'a')],
        visits: [
          _visit('v2', 'a', at: DateTime.utc(2026, 8, 21, 10)),
          _visit(
            'v1',
            'a',
            outcome: VisitOutcome.skipped,
            at: DateTime.utc(2026, 8, 21, 9),
          ),
        ],
      );

      expect(progress.entries.single.visitId, 'v2');
    });

    test('a visit with no timestamp still settles the stop', () {
      // It sorts oldest rather than being dropped: losing it would show a
      // settled stop as pending and send somebody back to a building they have
      // already been to.
      final progress = tourProgress(
        stops: [_stop('st1', 'a')],
        visits: [_visit('v1', 'a')],
      );

      expect(progress.entries.single.state, TourStopState.checked);
    });

    test('...and loses to one that has a timestamp', () {
      final progress = tourProgress(
        stops: [_stop('st1', 'a')],
        visits: [
          _visit('v1', 'a', outcome: VisitOutcome.skipped),
          _visit('v2', 'a', at: DateTime.utc(2026, 8, 21)),
        ],
      );

      expect(progress.entries.single.visitId, 'v2');
    });

    test('a building the template never listed lands AFTER the route', () {
      // Not inserted into the order: that would claim the template says
      // something it does not, and the reader is standing in front of the
      // template.
      final progress = tourProgress(
        stops: [_stop('st1', 'a'), _stop('st2', 'b')],
        visits: [_visit('v1', 'x', at: DateTime.utc(2026, 8, 21))],
      );

      expect(progress.entries.map((e) => e.spot), ['a', 'b', 'x']);
      expect(progress.entries.last.planned, isFalse);
      expect(progress.addedCount, 1);
      // An addition does not make the PLANNED route more finished.
      expect(progress.plannedCount, 2);
      expect(progress.plannedDone, 0);
    });

    test('additions are ordered by when they were visited', () {
      final progress = tourProgress(
        stops: const [],
        visits: [
          _visit('v1', 'late', at: DateTime.utc(2026, 8, 21, 12)),
          _visit('v2', 'early', at: DateTime.utc(2026, 8, 21, 8)),
        ],
      );

      expect(progress.entries.map((e) => e.spot), ['early', 'late']);
    });

    test('an ad-hoc round is every entry an addition', () {
      // A round with no template has no stops at all, and that is the whole
      // ad-hoc mode rather than a degenerate case of a route.
      final progress = tourProgress(
        stops: const [],
        visits: [_visit('v1', 'a'), _visit('v2', 'b')],
      );

      expect(progress.plannedCount, 0);
      expect(progress.addedCount, 2);
      // Nothing planned is nothing outstanding: the finish button must not be
      // the one control an ad-hoc round refuses.
      expect(progress.isComplete, isTrue);
      expect(progress.nextPending, isNull);
    });

    test('an empty round of nothing is complete', () {
      final progress = tourProgress(stops: const [], visits: const []);

      expect(progress.isComplete, isTrue);
    });

    test('a name comes from the expand, then from the loaded spots', () {
      final progress = tourProgress(
        stops: [
          _stop('st1', 'a', name: 'Vom Expand'),
          _stop('st2', 'b'),
        ],
        visits: const [],
        spotNames: const {'a': 'Ignoriert', 'b': 'Aus der Übersicht'},
      );

      expect(progress.entries.first.spotName, 'Vom Expand');
      expect(progress.entries.last.spotName, 'Aus der Übersicht');
    });

    test('an addition takes its name from its own visit expand', () {
      // An addition has no tour_spots row to read a name off, which is why the
      // run's visits are read with expand=spot.
      final progress = tourProgress(
        stops: const [],
        visits: [_visit('v1', 'x', spotName: 'Ergänzt')],
      );

      expect(progress.entries.single.spotName, 'Ergänzt');
    });

    test('an outcome this build has no name for counts as visited', () {
      // The building WAS visited. Offering it again as untouched is how a nest
      // gets checked twice in one round and the rhythm advances on the second
      // reading.
      final progress = tourProgress(
        stops: [_stop('st1', 'a')],
        visits: const [Visit(id: 'v1', spot: 'a', tourRun: 'r1')],
      );

      expect(progress.entries.single.state, TourStopState.checked);
      expect(progress.isComplete, isTrue);
    });

    test('a duplicated stop is counted once, not twice', () {
      // The collection has a unique index on (tour, spot) so this cannot be
      // stored — but if it ever were, one visit must not settle two rows and
      // report a route as more finished than it is.
      final progress = tourProgress(
        stops: [_stop('st1', 'a'), _stop('st2', 'a')],
        visits: [_visit('v1', 'a')],
      );

      expect(progress.plannedCount, 1);
      expect(progress.plannedDone, 1);
      expect(progress.entries.length, 1);
    });
  });
}
