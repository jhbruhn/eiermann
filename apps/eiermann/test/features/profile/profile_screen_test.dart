import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/profile/profile_screen.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:zugvogel_pb_client/zugvogel_pb_client.dart';

import '../../support/harness.dart';

class _MockAuth extends Mock implements AuthRepository {}

const _me = AppUser(
  id: 'u1',
  email: 'rita@eiermann.test',
  name: 'Rita',
  phone: '0170 1234567',
  role: UserRole.coordinator,
  org: 'org00000default',
);

void main() {
  late AppLocalizations de;
  late _MockAuth auth;

  setUpAll(() async {
    de = await germanStrings();
  });

  setUp(() {
    auth = _MockAuth();
    when(
      () => auth.updateProfile(
        name: any(named: 'name'),
        phone: any(named: 'phone'),
      ),
    ).thenAnswer((_) async => _me);
  });

  Future<void> pumpProfile(WidgetTester tester, {AppUser? me = _me}) async {
    // Tall surface: the sign-out is the LAST row of a ListView, and the default
    // 800x600 does not build what is below the fold — a missing button would
    // read as a missing feature.
    tester.useSurface(const Size(900, 1600));
    await tester.pumpApp(
      const ProfileScreen(),
      overrides: [
        currentUserProvider.overrideWith((ref) async => me),
        authRepositoryProvider.overrideWith((ref) async => auth),
        appVersionProvider.overrideWith((ref) async => '1.2.3'),
        serverInfoProvider.overrideWith(
          (ref) async => const ServerInfo(
            version: '1.2.0',
            name: 'Eiermann',
            auth: ServerAuthOptions(),
          ),
        ),
      ],
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the screen says who you are and what you may decide', (
    tester,
  ) async {
    await pumpProfile(tester);

    expect(find.text('Rita'), findsOneWidget);
    expect(find.text('rita@eiermann.test'), findsOneWidget);
    expect(find.text('0170 1234567'), findsOneWidget);
    // The same word the roster uses for the role, not a second vocabulary.
    expect(find.text(de.teamRoleCoordinator), findsOneWidget);
  });

  testWidgets('a nameless account says so rather than showing a blank', (
    tester,
  ) async {
    // Worth a row of its own: the visit history snapshots the author's NAME
    // when it is written, so an account with none writes its email address into
    // every Spot it touches.
    await pumpProfile(tester, me: const AppUser(id: 'u2', email: 'x@y.test'));

    expect(find.text(de.profileNameMissing), findsOneWidget);
  });

  testWidgets('both versions are on the screen', (tester) async {
    await pumpProfile(tester);

    expect(find.text('1.2.3'), findsOneWidget);
    expect(find.text('1.2.0'), findsOneWidget);
  });

  testWidgets('an unreachable server leaves the server row blank', (
    tester,
  ) async {
    tester.useSurface(const Size(900, 1600));
    await tester.pumpApp(
      const ProfileScreen(),
      overrides: [
        currentUserProvider.overrideWith((ref) async => _me),
        authRepositoryProvider.overrideWith((ref) async => auth),
        appVersionProvider.overrideWith((ref) async => '1.2.3'),
        // What an offline instance actually looks like: the provider resolves
        // to null rather than failing, and the row must not then claim a
        // version.
        serverInfoProvider.overrideWith((ref) async => null),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text(de.profileServerVersionLabel), findsOneWidget);
    expect(find.text('1.2.3'), findsOneWidget);
  });

  testWidgets('the edit sheet sends the name and the phone, nothing else', (
    tester,
  ) async {
    await pumpProfile(tester);

    await tester.tap(find.byTooltip(de.profileEditTitle));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, de.profileNameLabel),
      'Rita Neu',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, de.profilePhoneLabel),
      '0170 9999',
    );
    await tester.tap(find.text(de.actionSave));
    await tester.pumpAndSettle();

    // Exactly this call: the role, the org and the access flag are absent from
    // the method, so a self-edit cannot even spell the body `users.updateRule`
    // refuses.
    verify(
      () => auth.updateProfile(name: 'Rita Neu', phone: '0170 9999'),
    ).called(1);
  });

  testWidgets('an empty name is refused before the request', (tester) async {
    await pumpProfile(tester);

    await tester.tap(find.byTooltip(de.profileEditTitle));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, de.profileNameLabel),
      '',
    );
    await tester.tap(find.text(de.actionSave));
    await tester.pumpAndSettle();

    verifyNever(
      () => auth.updateProfile(
        name: any(named: 'name'),
        phone: any(named: 'phone'),
      ),
    );
  });

  testWidgets('the way out is here, and it clears the session', (tester) async {
    await pumpProfile(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, de.authSignOutAction));
    await tester.pumpAndSettle();

    verify(auth.signOut).called(1);
  });

  testWidgets('a profile nobody is signed in for offers no edit action', (
    tester,
  ) async {
    await pumpProfile(tester, me: null);

    expect(find.text(de.errorUnauthorized), findsOneWidget);
    expect(find.byTooltip(de.profileEditTitle), findsNothing);
  });
}
