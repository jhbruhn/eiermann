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

AuditEntry entry({
  String id = 'a1',
  String action = 'spot_phase_changed',
  String actorLabel = 'Rita',
  String? targetType = 'spot',
  String? target = 's1',
  String? targetLabel = 'Bahnhofstraße 12',
  String? field = 'phase',
  String? fromValue = 'active',
  String? toValue = 'closed',
  String? detail,
}) => AuditEntry(
  id: id,
  action: action,
  actorLabel: actorLabel,
  targetType: targetType,
  target: target,
  targetLabel: targetLabel,
  field: field,
  fromValue: fromValue,
  toValue: toValue,
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
    List<AuditEntry> entries, {
    String? targetId,
  }) async {
    tester.useSurface(const Size(900, 1600));
    when(
      () => audit.pageOfLog(after: any(named: 'after')),
    ).thenAnswer((_) async => PbPage(items: entries));
    when(
      () => audit.pageForTarget(any(), after: any(named: 'after')),
    ).thenAnswer((_) async => PbPage(items: entries));
    await tester.pumpApp(
      AuditScreen(targetId: targetId),
      overrides: [
        auditRepositoryProvider.overrideWith((ref) async => audit),
      ],
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an act reads as words, never as column names', (tester) async {
    // The whole point of eiermann-uwd.4, seen from the screen: the server sends
    // `spot_phase_changed` / `phase` / `active` / `closed` because it does not
    // know which language the reader speaks, and every one of those has to
    // arrive as German here.
    await pumpLog(tester, [entry()]);

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
    expect(find.textContaining('spot_phase_changed'), findsNothing);
    expect(find.textContaining('closed'), findsNothing);
  });

  testWidgets('a value with no predecessor is not shown as a blanked one', (
    tester,
  ) async {
    // An invite has no `from`: the account did not exist a moment ago.
    // Rendering "Rolle:  → Mitglied" would read as a value somebody cleared.
    await pumpLog(tester, [
      entry(
        action: 'user_invited',
        targetType: 'user',
        targetLabel: 'Neu',
        field: 'role',
        fromValue: '',
        toValue: 'member',
      ),
    ]);

    expect(
      find.text(de.auditChangeInitial(de.auditFieldRole, de.teamRoleMember)),
      findsOneWidget,
    );
  });

  testWidgets('a deleted target still reads as the name it had', (
    tester,
  ) async {
    // The reason `target` is a stored TEXT id and every label is a snapshot: a
    // relation would have had to choose between cascading — the deletion
    // erasing the record of itself — and dangling.
    await pumpLog(tester, [
      entry(
        action: 'spot_deleted',
        targetLabel: 'Alter Speicher',
        field: null,
        fromValue: null,
        toValue: null,
      ),
    ]);

    expect(find.text(de.auditActionSpotDeleted), findsOneWidget);
    expect(find.text('Alter Speicher'), findsOneWidget);
    // No arrow line at all: there is no before-and-after to a deletion.
    expect(find.textContaining('→'), findsNothing);
  });

  testWidgets('the release of a protected nest carries the species typed', (
    tester,
  ) async {
    // The act this whole table is most for. The species somebody wrote down is
    // the fact the decision rested on, and it sits on a field the very next
    // edit can overwrite.
    await pumpLog(tester, [
      entry(
        action: 'nest_unprotected',
        targetType: 'nest',
        targetLabel: 'N3',
        field: 'species',
        fromValue: 'protected',
        toValue: 'feral_pigeon',
        detail: 'Dohle',
      ),
    ]);

    expect(find.text(de.auditActionNestUnprotected), findsOneWidget);
    expect(find.text('Dohle'), findsOneWidget);
    expect(
      find.text(
        de.auditChange(
          de.auditFieldSpecies,
          de.auditValueSpeciesProtected,
          de.auditValueSpeciesFeralPigeon,
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('an actorless entry is attributed, not left blank', (
    tester,
  ) async {
    // The server writes `system` when there is no account to name — a cron,
    // a bootstrap. An entry with no author answers half the question it
    // exists for.
    await pumpLog(tester, [entry(actorLabel: '')]);

    expect(find.textContaining(de.auditActorSystem), findsOneWidget);
  });

  testWidgets('an empty log says what would go in it', (tester) async {
    await pumpLog(tester, const []);

    expect(find.text(de.auditEmptyTitle), findsOneWidget);
    expect(find.text(de.auditEmptyMessage), findsOneWidget);
  });

  testWidgets('a target id narrows the read to that target', (tester) async {
    // And through `pageForTarget`, which filters on the stored TEXT id — so it
    // still answers for a Spot that has since been deleted.
    await pumpLog(tester, [entry()], targetId: 's1');

    verify(() => audit.pageForTarget('s1')).called(1);
    verifyNever(() => audit.pageOfLog(after: any(named: 'after')));
  });
}
