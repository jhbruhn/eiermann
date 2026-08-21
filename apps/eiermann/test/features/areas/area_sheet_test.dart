import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/areas/area_sheet.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/harness.dart';

class _MockAreas extends Mock implements AreasRepository {}

void main() {
  late AppLocalizations de;
  late _MockAreas repo;

  setUpAll(() async {
    de = await germanStrings();
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() {
    repo = _MockAreas();
    when(() => repo.create(any())).thenAnswer(
      (_) async => const Area(id: 'a9', name: 'Dachboden Nord', spot: 's1'),
    );
    when(() => repo.update(any(), any())).thenAnswer(
      (_) async => const Area(id: 'a1', name: 'Dachboden Nord', spot: 's1'),
    );
    when(() => repo.forSpot(any())).thenAnswer((_) async => []);
  });

  Future<void> pump(WidgetTester tester, {Area? area}) async {
    await tester.pumpApp(
      Scaffold(
        body: AreaSheet(spotId: 's1', area: area),
      ),
      overrides: [
        areasRepositoryProvider.overrideWith((ref) async => repo),
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

  Map<String, dynamic> captureCreate() =>
      verify(() => repo.create(captureAny())).captured.single
          as Map<String, dynamic>;

  Map<String, dynamic> captureUpdate() =>
      verify(() => repo.update('a1', captureAny())).captured.single
          as Map<String, dynamic>;

  testWidgets("a new Bereich carries its Spot and the caller's org", (
    tester,
  ) async {
    // Every create rule in the schema pins `org` to the caller's own — it is
    // the one write that could cross tenancy.
    await pump(tester);
    await tester.enterText(
      find.byType(TextFormField).first,
      'Dachboden Nord',
    );
    await tester.tap(find.text(de.actionSave));
    await tester.pumpAndSettle();

    final body = captureCreate();
    expect(body['name'], 'Dachboden Nord');
    expect(body['spot'], 's1');
    expect(body['org'], 'org00000default');
  });

  testWidgets('a rename sends NEITHER the Spot nor the org', (tester) async {
    // The collection refuses both on update, and a re-parenting write would be
    // authorised against the old Spot while landing on the new one — taking the
    // Bereich's nests and their check history with it.
    await pump(
      tester,
      area: const Area(id: 'a1', name: 'Dachboden', spot: 's1'),
    );
    await tester.enterText(
      find.byType(TextFormField).first,
      'Dachboden Nord',
    );
    await tester.tap(find.text(de.actionSave));
    await tester.pumpAndSettle();

    final body = captureUpdate();
    expect(body['name'], 'Dachboden Nord');
    expect(body.containsKey('spot'), isFalse);
    expect(body.containsKey('org'), isFalse);
  });

  testWidgets('a nameless Bereich is refused before the request', (
    tester,
  ) async {
    // "Bereich" with no name is unfindable in a list of four, and the server
    // requires it — failing here gives the user the app's own error copy
    // instead of a 400.
    await pump(tester);

    await tester.tap(find.text(de.actionSave));
    await tester.pumpAndSettle();

    verifyNever(() => repo.create(any()));
  });

  testWidgets('the note is optional and travels with the Bereich', (
    tester,
  ) async {
    // What a photo cannot say and a pin cannot either: how to get up there.
    await pump(tester);
    await tester.enterText(find.byType(TextFormField).first, 'Dachboden Nord');
    await tester.enterText(find.byType(TextFormField).at(1), 'Luke im Flur');
    await tester.tap(find.text(de.actionSave));
    await tester.pumpAndSettle();

    expect(captureCreate()['note'], 'Luke im Flur');
  });

  testWidgets('the photo is NOT part of this form', (tester) async {
    // A Bereich has to exist before a file can be attached to it. Asking for
    // both at once means either a two-step save that can half-fail, or a camera
    // opening out of a form somebody is still typing in.
    await pump(tester);

    expect(find.text(de.areaPhotoSetAction), findsNothing);
    expect(find.text(de.photoCameraAction), findsNothing);
  });
}
