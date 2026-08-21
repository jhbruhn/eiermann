import 'package:eiermann_models/eiermann_models.dart';
import 'package:test/test.dart';

void main() {
  group('the Fund body', () {
    test('sends the wire value of the kind, not the Dart name', () {
      // The whole reason every enum in this app carries a `wire`: renaming
      // `otherSpecies` must not change what PocketBase stores.
      expect(
        const FindingDraft(kind: FindingKind.otherSpecies).toBody()['kind'],
        'other_species',
      );
      expect(
        const FindingDraft(kind: FindingKind.siteChange).toBody()['kind'],
        'site_change',
      );
    });

    test('states the count even at its default', () {
      // The hook's `Number(payload.count || 1)` makes an absent count the same
      // 1, but a body that says so is one a person can read in a log without
      // knowing the hook's default.
      expect(const FindingDraft(kind: FindingKind.chick).toBody()['count'], 1);
      expect(
        const FindingDraft(kind: FindingKind.chick, count: 4).toBody()['count'],
        4,
      );
    });

    test('a finding about the building sends no nest at all', () {
      // Not `nest: null` — absent. A dead bird on the floor of a stairwell
      // belongs to no nest, and the endpoint reads a falsy `payload.nest` as
      // exactly that.
      final body = const FindingDraft(kind: FindingKind.deadBird).toBody();
      expect(body.containsKey('nest'), isFalse);
    });

    test('a finding on a nest names it', () {
      final body = const FindingDraft(
        kind: FindingKind.deadBird,
        nest: 'n1',
        nestLabel: 'N1',
      ).toBody();

      expect(body['nest'], 'n1');
      // The label is for this app's own lines. Sending it would invite the
      // server to trust a name the client made up; it has the nest and reads
      // its own.
      expect(body.containsKey('nest_label'), isFalse);
    });

    test('empty text is absent, not an empty string', () {
      // A species field somebody focused and left blank must not become a row
      // in `species_labels` — the picker would then offer a blank entry, which
      // reads as a bug in the app.
      final body = const FindingDraft(
        kind: FindingKind.deadBird,
        speciesLabel: '',
        note: '',
      ).toBody();

      expect(body.containsKey('species_label'), isFalse);
      expect(body.containsKey('note'), isFalse);
    });

    test('only a structural change suggests closing the Spot', () {
      // A netted building is the path by which a Spot eventually closes. A dead
      // pigeon is not, however sad — and offering the closing on every Fund
      // would make the offer meaningless.
      expect(
        const FindingDraft(kind: FindingKind.siteChange).suggestsClosing,
        isTrue,
      );
      for (final kind in [
        FindingKind.deadBird,
        FindingKind.chick,
        FindingKind.otherSpecies,
      ]) {
        expect(FindingDraft(kind: kind).suggestsClosing, isFalse);
      }
    });
  });

  group('the Funde inside a visit', () {
    test('travel in the same body as the checks', () {
      final body = const VisitDraft(
        spot: 's1',
        outcome: VisitOutcome.checked,
        findings: [
          FindingDraft(kind: FindingKind.deadBird, speciesLabel: 'Dohle'),
          FindingDraft(kind: FindingKind.chick, count: 2),
        ],
      ).toBody();

      final findings = body['findings'] as List;
      expect(findings.length, 2);
      expect((findings.first as Map)['species_label'], 'Dohle');
      expect((findings.last as Map)['count'], 2);
    });

    test('the key is present even when there are none', () {
      // The Idempotency-Key hashes the canonical body, so a body whose SHAPE
      // depends on its own contents is one whose fingerprint moves for reasons
      // that have nothing to do with what was recorded.
      final body = const VisitDraft(
        spot: 's1',
        outcome: VisitOutcome.checked,
      ).toBody();

      expect(body.containsKey('findings'), isTrue);
      expect(body['findings'], isEmpty);
    });

    test('a SKIPPED visit may carry them', () {
      // "Netz an der Nordseite, nicht mehr reingekommen" is a non-event whose
      // reason is a Fund, seen from outside. The endpoint refuses checks on a
      // skip and accepts findings, and this side must not be stricter than it:
      // the alternative is a volunteer with nowhere to record why they turned
      // round.
      const draft = VisitDraft(
        spot: 's1',
        outcome: VisitOutcome.skipped,
        skipReason: SkipReason.accessBlocked,
        findings: [FindingDraft(kind: FindingKind.siteChange)],
      );

      expect(draft.isSendable, isTrue);
      expect((draft.toBody()['findings'] as List).length, 1);
      expect(draft.suggestsClosing, isTrue);
    });

    test('a visit with no structural change suggests nothing', () {
      expect(
        const VisitDraft(
          spot: 's1',
          outcome: VisitOutcome.checked,
          findings: [FindingDraft(kind: FindingKind.deadBird)],
        ).suggestsClosing,
        isFalse,
      );
    });
  });
}
