import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/spots/spot_detail_screen.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/harness.dart';

class _MockSpots extends Mock implements SpotsRepository {}

class _MockContacts extends Mock implements SpotContactsRepository {}

class _MockAreas extends Mock implements AreasRepository {}

class _MockNestStates extends Mock implements NestStateRepository {}

class _MockFollowUps extends Mock implements FollowUpsRepository {}

void main() {
  late AppLocalizations de;
  late _MockSpots spots;
  late _MockContacts contacts;
  late _MockAreas areas;
  late _MockNestStates nestStates;
  late _MockFollowUps followUps;

  setUpAll(() async {
    de = await germanStrings();
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() {
    spots = _MockSpots();
    contacts = _MockContacts();
    areas = _MockAreas();
    nestStates = _MockNestStates();
    followUps = _MockFollowUps();
    when(() => nestStates.forSpot(any())).thenAnswer((_) async => []);
    when(() => followUps.openForSpot(any())).thenAnswer((_) async => []);
    // The dossier reads the Bereiche now. Empty by default: what the Bereich
    // block itself does has its own test file.
    when(() => areas.forSpot(any())).thenAnswer((_) async => []);
  });

  const spot = Spot(
    id: 's1',
    name: 'Bahnhofstraße 12',
    street: 'Bahnhofstraße 12',
    postalCode: '26122',
    city: 'Oldenburg',
    phase: SpotPhase.active,
    prospectStage: ProspectStage.permitted,
    accessNote: 'Klingel Hausmeister Kröger, Schlüssel im Kasten links',
  );

  const caretaker = SpotContact(
    id: 'c1',
    spot: 's1',
    name: 'Herr Kröger',
    role: ContactRole.caretaker,
    phone: '0441 123456',
    note: 'nur vormittags erreichbar, klingelt nicht bei Regen',
    isPrimary: true,
  );

  /// A nest of this building, for the blocks that read the clutch.
  NestState nestRow({
    String id = 'n1',
    String label = 'N1',
    int real = 0,
    int dummy = 0,
    int? interval,
    int? streak,
  }) => NestState(
    id: id,
    label: label,
    area: 'a1',
    urgency: 3,
    spot: 's1',
    realCount: real,
    dummyCount: dummy,
    intervalDays: interval,
    emptyStreak: streak,
  );

  Future<void> pumpDetail(
    WidgetTester tester, {
    Spot record = spot,
    List<SpotContact> rows = const [caretaker],
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    when(() => spots.getOne(any())).thenAnswer((_) async => record);
    when(() => contacts.forSpot(any())).thenAnswer((_) async => rows);
    when(
      () => spots.update(any(), any()),
    ).thenAnswer((_) async => record);
    await tester.pumpApp(
      const SpotDetailScreen(spotId: 's1'),
      overrides: [
        spotsRepositoryProvider.overrideWith((ref) async => spots),
        spotContactsRepositoryProvider.overrideWith((ref) async => contacts),
        areasRepositoryProvider.overrideWith((ref) async => areas),
        nestStateRepositoryProvider.overrideWith((ref) async => nestStates),
        followUpsRepositoryProvider.overrideWith((ref) async => followUps),
        currentUserProvider.overrideWith(
          (ref) async => const AppUser(
            id: 'u1',
            email: 'feld@eiermann.test',
            role: UserRole.member,
            org: 'org00000default',
          ),
        ),
      ],
    );
    await tester.pumpAndSettle();
  }

  group('the access note', () {
    testWidgets('is shown, and is what the card is for', (tester) async {
      await pumpDetail(tester);

      expect(find.text(de.spotAccessTitle), findsOneWidget);
      expect(find.text(spot.accessNote!), findsOneWidget);
    });

    testWidgets('stands there even when EMPTY, saying what is missing', (
      tester,
    ) async {
      // The unusual half and the point of the card: a Spot with no access note
      // is a handover that will cost somebody a phone call, and hiding the gap
      // is how it stays a gap.
      await pumpDetail(tester, record: spot.copyWith(accessNote: null));

      expect(find.text(de.spotAccessEmpty), findsOneWidget);
    });

    testWidgets('opens its own editor in ONE tap, from the empty card too', (
      tester,
    ) async {
      await pumpDetail(tester, record: spot.copyWith(accessNote: null));
      await tester.tap(find.text(de.spotAccessEmpty));
      await tester.pumpAndSettle();

      expect(find.text(de.spotAccessSheetTitle), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, de.spotFieldAccessNote),
        'Seiteneingang, Code 1980',
      );
      await tester.tap(find.text(de.actionSave));
      await tester.pumpAndSettle();

      final body =
          verify(() => spots.update('s1', captureAny())).captured.single
              as Map<String, dynamic>;
      // One key. The sheet owns one field and must not rewrite the five it
      // never showed.
      expect(body, {'access_note': 'Seiteneingang, Code 1980'});
    });
  });

  group('the contacts', () {
    testWidgets('name the one to ring first, in words', (tester) async {
      await pumpDetail(tester);

      expect(find.text(caretaker.name), findsOneWidget);
      // Role and number share the first line, exactly — asserted as the whole
      // string rather than as "contains Hausmeister", which also matches the
      // access note above it ("Klingel Hausmeister Kröger").
      expect(
        find.text('${de.contactRoleCaretaker} · ${caretaker.phone}'),
        findsOneWidget,
      );
      // "Zuerst anrufen" is spelled out rather than shown as a star, because it
      // is a fact somebody reads, not decoration.
      expect(find.text(de.spotContactPrimary), findsOneWidget);
    });

    testWidgets('show the note IN FULL, on its own line', (tester) async {
      // It was joined onto the end of the role line, which a ListTile
      // subtitle ellipsises — and that sentence is the handover itself.
      await pumpDetail(tester);

      expect(find.text(caretaker.note!), findsOneWidget);
    });

    testWidgets('offer a call, and a way to remove a number that is wrong', (
      tester,
    ) async {
      await pumpDetail(tester);
      expect(find.byTooltip(de.spotContactCallAction), findsOneWidget);

      await tester.tap(find.text(caretaker.name));
      await tester.pumpAndSettle();
      expect(find.text(de.spotContactDeleteAction), findsOneWidget);

      when(() => contacts.delete(any())).thenAnswer((_) async {});
      await tester.tap(find.text(de.spotContactDeleteAction));
      await tester.pumpAndSettle();

      // Asks first, and names what is lost — the number exists nowhere else.
      expect(find.text(de.spotContactDeleteTitle), findsOneWidget);
      verifyNever(() => contacts.delete(any()));

      await tester.tap(find.text(de.spotContactDeleteAction).last);
      await tester.pumpAndSettle();
      verify(() => contacts.delete('c1')).called(1);
    });

    testWidgets('an empty list says what the gap costs', (tester) async {
      await pumpDetail(tester, rows: const []);

      expect(find.text(de.spotContactsEmpty), findsOneWidget);
    });
  });

  group('the header', () {
    testWidgets('a closed Spot shows the reason and the date', (tester) async {
      // The only question anybody asks of a closed Spot six months on is
      // whether it is worth asking again, and the reason is the answer.
      await pumpDetail(
        tester,
        record: spot.copyWith(
          phase: SpotPhase.closed,
          closedReason: ClosedReason.permissionWithdrawn,
          closedAt: DateTime.utc(2026, 8, 3),
          nextDueAt: null,
        ),
      );

      expect(
        find.textContaining(de.closedReasonPermissionWithdrawn),
        findsOneWidget,
      );
      expect(find.text(de.spotPhaseClosed), findsOneWidget);
    });

    testWidgets('a missing pin is stated, not left to be guessed', (
      tester,
    ) async {
      // A guessed pin on the wrong side of a courtyard sends somebody to the
      // wrong door, so "no pin" and "unconfirmed pin" are different sentences.
      await pumpDetail(tester);

      expect(find.textContaining(de.spotPinMissing), findsOneWidget);
    });
  });

  group('the visit', () {
    testWidgets('both outcomes are offered as equal-rank buttons', (
      tester,
    ) async {
      // "Nicht geprüft" is not an error path: somebody stood in front of the
      // building and did not get in, and that is a fact about the building.
      // Giving it a lesser control teaches people to leave instead.
      await pumpDetail(tester);

      expect(find.text(de.visitStartAction), findsOneWidget);
      expect(find.text(de.visitSkipAction), findsOneWidget);
    });

    testWidgets('an Erkundung is not offered a visit at all', (tester) async {
      // It needs a conversation, not a round — and putting a visit funnel on it
      // would make the wrong action the most prominent one on the screen.
      await pumpDetail(
        tester,
        record: spot.copyWith(
          phase: SpotPhase.prospect,
          prospectStage: ProspectStage.ownerSpoken,
        ),
      );

      expect(find.text(de.visitStartAction), findsNothing);
      expect(find.text(de.visitSkipAction), findsNothing);
    });

    testWidgets('a PAUSED Spot keeps them — that is how a pause ends', (
      tester,
    ) async {
      // Deliberately temporary: going past to see whether the scaffolding is
      // gone is exactly the visit that ends it.
      await pumpDetail(tester, record: spot.copyWith(phase: SpotPhase.paused));

      expect(find.text(de.visitStartAction), findsOneWidget);
    });

    testWidgets('the Attrappen to pack are on the dossier', (tester) async {
      // The concept's smallest feature with the highest everyday value: it
      // replaces guessing at the car, so it has to be on the screen somebody
      // reads before leaving.
      when(() => nestStates.forSpot('s1')).thenAnswer(
        (_) async => [
          nestRow(dummy: 1, real: 1),
          nestRow(id: 'n2', label: 'N2'),
        ],
      );

      await pumpDetail(tester);

      // 1 for the nest that holds one dummy, 2 for the empty one.
      expect(find.text(de.spotPackDummies(3)), findsOneWidget);
    });

    testWidgets('a Nachkontrolle explains the due date, naming the nest', (
      tester,
    ) async {
      // Built in the CLIENT: the server does not know which language the reader
      // speaks. And the follow-up is usually what makes the Spot due, because
      // it is earlier than the ladder would have come round.
      final due = DateTime.now().add(const Duration(days: 2));
      when(() => nestStates.forSpot('s1')).thenAnswer(
        (_) async => [nestRow(id: 'n3', label: 'N3', interval: 7, streak: 0)],
      );
      when(() => followUps.openForSpot('s1')).thenAnswer(
        (_) async => [
          FollowUp(
            id: 'f1',
            spot: 's1',
            nest: 'n3',
            dueAt: due,
            reason: FollowUpReason.halfClutch,
          ),
        ],
      );

      await pumpDetail(
        tester,
        record: spot.copyWith(nextDueAt: due),
      );

      expect(
        find.textContaining(de.dueExplainFollowUp('N3')),
        findsOneWidget,
      );
    });
  });
}
