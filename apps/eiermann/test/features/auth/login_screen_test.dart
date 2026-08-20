import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/auth/login_screen.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:zugvogel_pb_client/zugvogel_pb_client.dart';

import '../../support/harness.dart';

class _MockAuth extends Mock implements AuthRepository {}

AppUser user({bool active = true}) => AppUser(
  id: 'u1',
  email: 'feld@eiermann.test',
  role: UserRole.member,
  org: 'org00000default',
  isActive: active,
);

ServerInfo info({
  String version = '1.0.0',
  bool passwordReset = false,
}) => ServerInfo(
  version: version,
  name: 'Wildvogelhilfe Ost',
  auth: ServerAuthOptions(passwordReset: passwordReset),
);

void main() {
  late AppLocalizations de;
  late _MockAuth auth;

  setUpAll(() async {
    de = await germanStrings();
    registerFallbackValue('');
  });

  setUp(() => auth = _MockAuth());

  Future<void> pump(
    WidgetTester tester, {
    ServerInfo? serverInfo,
    ServerCompatibility compatibility = ServerCompatibility.compatible,
  }) => tester.pumpApp(
    const LoginScreen(),
    overrides: [
      authRepositoryProvider.overrideWith((ref) async => auth),
      serverInfoProvider.overrideWith((ref) async => serverInfo ?? info()),
      serverCompatibilityProvider.overrideWith((ref) async => compatibility),
    ],
  );

  testWidgets('shows the instance name the server reported', (tester) async {
    // Not the app's own name: a team should see which server they are signing
    // in to, especially when an organisation runs more than one.
    await pump(tester);
    await tester.pumpAndSettle();
    expect(find.text('Wildvogelhilfe Ost'), findsOneWidget);
  });

  testWidgets('an empty form is refused before any request', (tester) async {
    await pump(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text(de.authSignInAction));
    await tester.pumpAndSettle();

    expect(find.text(de.fieldRequired), findsWidgets);
    verifyNever(() => auth.signIn(any(), any()));
  });

  testWidgets('wrong credentials get the credentials message, not a generic '
      'one', (tester) async {
    when(() => auth.signIn(any(), any())).thenThrow(
      const RepositoryException('bad', kind: RepositoryErrorKind.validation),
    );
    await pump(tester);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, de.authEmailLabel),
      'feld@eiermann.test',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, de.authPasswordLabel),
      'wrong-password',
    );
    await tester.tap(find.text(de.authSignInAction));
    await tester.pumpAndSettle();

    expect(find.text(de.authErrorInvalidCredentials), findsOneWidget);
  });

  testWidgets('offline gets the offline message, so the user knows to retry '
      'later', (tester) async {
    when(() => auth.signIn(any(), any())).thenThrow(
      const RepositoryException('down', kind: RepositoryErrorKind.network),
    );
    await pump(tester);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, de.authEmailLabel),
      'feld@eiermann.test',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, de.authPasswordLabel),
      'secret1234',
    );
    await tester.tap(find.text(de.authSignInAction));
    await tester.pumpAndSettle();

    expect(find.text(de.errorOffline), findsOneWidget);
    expect(find.text(de.authErrorInvalidCredentials), findsNothing);
  });

  testWidgets('a DEACTIVATED account is told so, and signed back out', (
    tester,
  ) async {
    // The server answers 400 for a deactivated account — deliberately
    // indistinguishable from a wrong password, so an attacker learns nothing.
    // That leaves the honest message to the client, once it is holding the
    // record. And the session has to be dropped again: it is valid, and leaving
    // it would let the router in.
    when(
      () => auth.signIn(any(), any()),
    ).thenAnswer((_) async => user(active: false));
    await pump(tester);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, de.authEmailLabel),
      'feld@eiermann.test',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, de.authPasswordLabel),
      'secret1234',
    );
    await tester.tap(find.text(de.authSignInAction));
    await tester.pumpAndSettle();

    expect(find.text(de.authErrorDeactivated), findsOneWidget);
    verify(() => auth.signOut()).called(1);
  });

  group('the version notice names which side is behind', () {
    testWidgets('an old app tells the user to update the app', (tester) async {
      await pump(tester, compatibility: ServerCompatibility.clientTooOld);
      await tester.pumpAndSettle();
      expect(find.text(de.authVersionClientTooOld), findsOneWidget);
    });

    testWidgets('an old SERVER points at the operator', (tester) async {
      // Telling this user to update their app would be a dead end: their app is
      // already the newer of the two, and an unattended APK updater makes that
      // the common case.
      await pump(tester, compatibility: ServerCompatibility.serverTooOld);
      await tester.pumpAndSettle();
      expect(find.text(de.authVersionServerTooOld), findsOneWidget);
      expect(find.text(de.authVersionClientTooOld), findsNothing);
    });

    testWidgets('a compatible pair shows no notice at all', (tester) async {
      await pump(tester);
      await tester.pumpAndSettle();
      expect(find.text(de.authVersionClientTooOld), findsNothing);
      expect(find.text(de.authVersionServerTooOld), findsNothing);
    });
  });

  group('password reset is offered only when it can work', () {
    testWidgets('hidden when the server has no SMTP', (tester) async {
      // Otherwise it is a button that silently does nothing — the server cannot
      // deliver the mail and the user is left waiting for it.
      await pump(tester, serverInfo: info());
      await tester.pumpAndSettle();
      expect(find.text(de.authForgotPasswordAction), findsNothing);
    });

    testWidgets('offered when it can, and never confirms the address exists', (
      tester,
    ) async {
      when(() => auth.requestPasswordReset(any())).thenAnswer((_) async {});
      await pump(tester, serverInfo: info(passwordReset: true));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, de.authEmailLabel),
        'feld@eiermann.test',
      );
      await tester.tap(find.text(de.authForgotPasswordAction));
      await tester.pumpAndSettle();

      // The same message either way: saying "no such account" would let anyone
      // enumerate the team's addresses.
      expect(find.text(de.authResetSentMessage), findsOneWidget);
    });

    testWidgets('...and says the same thing when the request FAILS', (
      tester,
    ) async {
      when(
        () => auth.requestPasswordReset(any()),
      ).thenThrow(const RepositoryException('nope'));
      await pump(tester, serverInfo: info(passwordReset: true));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, de.authEmailLabel),
        'nobody@eiermann.test',
      );
      await tester.tap(find.text(de.authForgotPasswordAction));
      await tester.pumpAndSettle();

      expect(find.text(de.authResetSentMessage), findsOneWidget);
    });
  });
}
