import 'package:eiermann/features/rhythm/due_explanation.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/harness.dart';

NestState nest({
  int? interval,
  int? streak,
  DateTime? lastCheckedAt,
  NestSpecies species = NestSpecies.feralPigeon,
  NestStatus status = NestStatus.active,
}) => NestState(
  id: 'n1',
  label: 'N3',
  area: 'a1',
  urgency: 3,
  species: species,
  status: status,
  intervalDays: interval,
  emptyStreak: streak,
  lastCheckedAt: lastCheckedAt,
);

Spot spot({
  SpotPhase phase = SpotPhase.active,
  DateTime? nextDueAt,
}) =>
    Spot(id: 's1', name: 'Bahnhofstr. 12', phase: phase, nextDueAt: nextDueAt);

FollowUp followUp({
  DateTime? dueAt,
  FollowUpReason reason = FollowUpReason.halfClutch,
  String? nestId = 'n1',
}) => FollowUp(
  id: 'f1',
  spot: 's1',
  nest: nestId,
  dueAt: dueAt,
  reason: reason,
);

void main() {
  late AppLocalizations de;

  setUpAll(() async => de = await germanStrings());

  group('a nest', () {
    test('names the ladder rung it is on and what got it there', () {
      // The concept's own sentence. A date without its reason is a date people
      // override; with the reason it is a decision they can argue with.
      expect(
        nestDueExplanation(de, nest(interval: 14, streak: 4)),
        de.dueExplainAfterEmpties(4, 14),
      );
    });

    test('does not claim "stretched" — it cannot know the base', () {
      // The base interval and the ladder live in organisations.settings, whose
      // only reader is the server's zv_org.js. Mapping that JSON field a second
      // time is the trap that silently disabled federfall's configurable
      // windows, so the client states its two facts and leaves the comparison
      // alone.
      expect(
        nestDueExplanation(de, nest(interval: 14, streak: 4)),
        isNot(contains('gestreckt')),
      );
    });

    test('a nest that found something reads as the plain rhythm', () {
      expect(
        nestDueExplanation(de, nest(interval: 7, streak: 0)),
        de.dueExplainBase(7),
      );
    });

    test('a nest nobody has been to says nothing here', () {
      // The line's own age column already reads "noch nie geprüft", and the
      // same words twice on one line is noise. The rhythm has nothing to
      // explain until a check has moved it.
      expect(nestDueExplanation(de, nest()), isNull);
    });

    test('the two states that leave the due lists say so', () {
      expect(
        nestDueExplanation(de, nest(status: NestStatus.gone, interval: 7)),
        de.dueExplainGone,
      );
      expect(
        nestDueExplanation(
          de,
          nest(species: NestSpecies.protected, interval: 7),
        ),
        de.dueExplainProtected,
      );
    });
  });

  group('a building', () {
    test('names the Nachkontrolle and the nest, when that is what won', () {
      // The follow-up usually IS what makes the Spot due — it is earlier than
      // the ladder would have come round, and that is the entire point of it.
      final due = DateTime(2026, 8, 25);
      expect(
        spotDueExplanation(
          de,
          spot(nextDueAt: due),
          followUps: [followUp(dueAt: due)],
          nests: [nest(interval: 7, streak: 0)],
          nestLabelOf: (_) => 'N3',
        ),
        de.dueExplainFollowUp('N3'),
      );
    });

    test('says less rather than showing an id', () {
      // An id with no label next to it is a bug in this app.
      final due = DateTime(2026, 8, 25);
      expect(
        spotDueExplanation(
          de,
          spot(nextDueAt: due),
          followUps: [followUp(dueAt: due)],
          nests: [nest(interval: 7)],
          nestLabelOf: (_) => null,
        ),
        de.dueExplainFollowUpNoNest,
      );
    });

    test('a manual Nachkontrolle says who put it there', () {
      final due = DateTime(2026, 8, 25);
      expect(
        spotDueExplanation(
          de,
          spot(nextDueAt: due),
          followUps: [followUp(dueAt: due, reason: FollowUpReason.manual)],
          nests: [nest(interval: 7)],
        ),
        de.dueExplainFollowUpManual,
      );
    });

    test(
      'a nest date that beats the follow-up leaves the sentence to the nest',
      () {
        // Both would otherwise be on one screen saying the loudest thing twice.
        expect(
          spotDueExplanation(
            de,
            spot(nextDueAt: DateTime(2026, 8, 20)),
            followUps: [followUp(dueAt: DateTime(2026, 8, 25))],
            nests: [nest(interval: 7, streak: 0)],
          ),
          isNull,
        );
      },
    );

    test('a building with no nests is due after the base period', () {
      // Empty does not mean done: a building with no nests recorded is one
      // nobody has looked at properly, and it must not drop out of the list.
      expect(
        spotDueExplanation(de, spot(nextDueAt: DateTime(2026, 8, 25))),
        de.dueExplainNoNests,
      );
    });

    test('the phases with no date at all say why', () {
      // Said out loud rather than left blank: no date and no explanation reads
      // as an oversight.
      expect(
        spotDueExplanation(de, spot(phase: SpotPhase.paused)),
        de.dueExplainPaused,
      );
      expect(
        spotDueExplanation(de, spot(phase: SpotPhase.closed)),
        de.dueExplainClosed,
      );
      expect(
        spotDueExplanation(de, spot(phase: SpotPhase.prospect)),
        de.dueExplainProspect,
      );
    });
  });
}
