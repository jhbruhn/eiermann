import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/audit/audit_screen.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/harness.dart';

class _MockAudit extends Mock implements AuditRepository {}

AuditEvent event({
  String id = 'a1',
  String action = 'spot.phase_changed',
  String actorLabel = 'Rita',
  String? actorKind = 'user',
  String? subjectCollection = 'spots',
  String? subjectId = 's1',
  String? subjectLabel = 'Bahnhofstraße 12',
  String? spotId = 's1',
  String? spotLabel = 'Bahnhofstraße 12',
  List<AuditChange> changes = const [
    AuditChange(field: 'phase', from: 'active', to: 'closed'),
  ],
  Map<String, dynamic> detail = const <String, dynamic>{},
}) => AuditEvent(
  id: id,
  action: action,
  actorLabel: actorLabel,
  actorKind: actorKind,
  subjectCollection: subjectCollection,
  subjectId: subjectId,
  subjectLabel: subjectLabel,
  spotId: spotId,
  spotLabel: spotLabel,
  changes: changes,
  detail: detail,
  createdAt: DateTime.utc(2026, 8, 20, 14, 30),
);

void main() {
  late AppLocalizations de;
  late _MockAudit audit;

  setUpAll(() async {
    de = await germanStrings();
  });

  setUp(() {
    audit = _MockAudit();
  });

  Future<void> pumpLog(
    WidgetTester tester,
    List<AuditEvent> events, {
    String? spotId,
  }) async {
    tester.useSurface(const Size(900, 1600));
    when(
      () => audit.pageOfLog(after: any(named: 'after')),
    ).thenAnswer((_) async => PbPage(items: events));
    when(
      () => audit.pageForSpot(any(), after: any(named: 'after')),
    ).thenAnswer((_) async => PbPage(items: events));
    await tester.pumpApp(
      AuditScreen(spotId: spotId),
      overrides: [auditRepositoryProvider.overrideWith((ref) async => audit)],
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an act reads as words, never as column names', (tester) async {
    // The whole point of the vocabulary guard, seen from the screen: the server
    // sends `spot.phase_changed` / `phase` / `active` / `closed` because it does
    // not know which language the reader speaks, and every one of those has to
    // arrive as German here.
    await pumpLog(tester, [event()]);

    expect(find.text(de.auditActionSpotPhaseChanged), findsOneWidget);
    expect(find.text('Bahnhofstraße 12'), findsOneWidget);
    expect(
      find.text(
        de.auditChange(
          de.auditFieldPhase,
          de.spotPhaseActive,
          de.spotPhaseClosed,
        ),
      ),
      findsOneWidget,
    );
    // Nothing raw anywhere on the tile.
    expect(find.textContaining('spot.phase_changed'), findsNothing);
    expect(find.textContaining('closed'), findsNothing);
  });

  testWidgets('several fields moving read as several lines', (tester) async {
    // The shape difference from the old log, seen from the screen: one row now
    // carries every field that moved, and each still gets its own sentence.
    // Collapsing them into one line would bury the number somebody changed.
    await pumpLog(tester, [
      event(
        action: 'nest.updated',
        subjectCollection: 'nests',
        subjectLabel: 'N3',
        changes: const [
          AuditChange(field: 'label', from: 'N2', to: 'N3'),
          AuditChange(field: 'interval_days', from: '14', to: '21'),
        ],
      ),
    ]);

    expect(
      find.text(de.auditChange(de.auditFieldLabel, 'N2', 'N3')),
      findsOneWidget,
    );
    expect(
      find.text(de.auditChange(de.auditFieldIntervalDays, '14', '21')),
      findsOneWidget,
    );
  });

  testWidgets('a withheld value is not rendered as an empty one', (
    tester,
  ) async {
    // A caretaker's phone number, a password, prose somebody can still correct.
    // The log kept the FACT of the change and dropped the value on purpose, and
    // a blank line would tell the reader nothing happened.
    await pumpLog(tester, [
      event(
        action: 'contact.updated',
        subjectCollection: 'spot_contacts',
        subjectLabel: '',
        changes: const [AuditChange(field: 'phone', redacted: true)],
      ),
    ]);

    expect(find.text(de.auditRedacted(de.auditFieldPhone)), findsOneWidget);
    // And no arrow, which is what a change with two empty sides would draw.
    expect(find.textContaining('→'), findsNothing);
  });

  testWidgets('a value with no predecessor is not shown as a blanked one', (
    tester,
  ) async {
    // An invitation has no `from`: the account did not exist a moment ago.
    // Rendering "Rolle:  → Mitglied" would read as a value somebody cleared.
    await pumpLog(tester, [
      event(
        action: 'user.invited',
        subjectCollection: 'users',
        subjectLabel: 'Neu',
        spotId: '',
        spotLabel: '',
        changes: const [AuditChange(field: 'role', to: 'member')],
      ),
    ]);

    expect(
      find.text(de.auditChangeInitial(de.auditFieldRole, de.teamRoleMember)),
      findsOneWidget,
    );
  });

  testWidgets('a cleared value says what it used to be', (tester) async {
    // The delete half of the shared `changes` shape: one renderer serves all
    // three verbs, and "cleared, was X" is the right sentence for something
    // that no longer exists.
    await pumpLog(tester, [
      event(
        action: 'spot.updated',
        changes: const [AuditChange(field: 'city', from: 'Berlin')],
      ),
    ]);

    expect(
      find.text(de.auditChangeCleared(de.auditFieldCity, 'Berlin')),
      findsOneWidget,
    );
  });

  testWidgets('a deleted subject still reads as the name it had', (
    tester,
  ) async {
    // The reason `subject_id` is a stored TEXT id and every label is a
    // snapshot: a relation would have had to choose between cascading — the
    // deletion erasing the record of itself — and dangling.
    await pumpLog(tester, [
      event(
        action: 'spot.deleted',
        subjectLabel: 'Alter Speicher',
        spotLabel: 'Alter Speicher',
        changes: const [],
      ),
    ]);

    expect(find.text(de.auditActionSpotDeleted), findsOneWidget);
    expect(find.text('Alter Speicher'), findsOneWidget);
    // No arrow line at all: there is no before-and-after to a deletion.
    expect(find.textContaining('→'), findsNothing);
  });

  testWidgets('a Besuch names its building and counts its children', (
    tester,
  ) async {
    // One human act, one row. The checks and findings it wrote are in `detail`
    // as counts rather than as events of their own, and the nested state maps
    // are deliberately not rendered — they belong in the Besuch itself.
    await pumpLog(tester, [
      event(
        action: 'visit.recorded',
        subjectCollection: 'visits',
        detail: const {
          'outcome': 'checked',
          'checks': 3,
          'states': {'empty': 3},
        },
      ),
    ]);

    expect(find.text(de.auditActionVisitRecorded), findsOneWidget);
    expect(find.textContaining('${de.auditFieldChecks}: 3'), findsOneWidget);
    // The nested map is not printed as a Dart Map literal.
    expect(find.textContaining('{'), findsNothing);
  });

  testWidgets('an act nobody performed says which schedule did', (
    tester,
  ) async {
    // A Spot leaving a pause was decided by a cron. Attributing it to the
    // coordinator who paused it would be a false statement about a person, and
    // a bare "System" leaves the reader guessing.
    await pumpLog(tester, [
      event(
        action: 'spot.auto_resumed',
        actorLabel: '',
        actorKind: 'cron',
        changes: const [],
      ),
    ]);

    expect(find.textContaining(de.auditActorKindCron), findsOneWidget);
  });

  testWidgets('an actorless entry is attributed, not left blank', (
    tester,
  ) async {
    // An entry with no author answers half the question it exists for.
    await pumpLog(tester, [event(actorLabel: '', actorKind: null)]);

    expect(find.textContaining(de.auditActorSystem), findsOneWidget);
  });

  testWidgets('an empty log says what would go in it', (tester) async {
    await pumpLog(tester, const []);

    expect(find.text(de.auditEmptyTitle), findsOneWidget);
    expect(find.text(de.auditEmptyMessage), findsOneWidget);
  });

  testWidgets('a Spot id narrows the read to that building', (tester) async {
    // Through `pageForSpot`, which filters on the stored TEXT id — so it still
    // answers for a Spot that has since been deleted, and returns everything
    // that happened THERE rather than only the Spot record's own edits.
    await pumpLog(tester, [event()], spotId: 's1');

    verify(() => audit.pageForSpot('s1')).called(1);
    verifyNever(() => audit.pageOfLog(after: any(named: 'after')));
  });
}
