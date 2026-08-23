import 'dart:async';

import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/auth/login_screen.dart';
import 'package:eiermann/features/auth/oauth_providers.dart';
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
  bool password = true,
  List<String> oauth2 = const [],
  Map<String, List<String>> oauth2Scopes = const {},
}) => ServerInfo(
  version: version,
  name: 'Wildvogelhilfe Ost',
  auth: ServerAuthOptions(
    passwordReset: passwordReset,
    password: password,
    oauth2: oauth2,
    oauth2Scopes: oauth2Scopes,
  ),
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
    List<OAuthProvider> providers = const [],
  }) => tester.pumpApp(
    const LoginScreen(),
    overrides: [
      authRepositoryProvider.overrideWith((ref) async => auth),
      serverInfoProvider.overrideWith((ref) async => serverInfo ?? info()),
      serverCompatibilityProvider.overrideWith((ref) async => compatibility),
      oauthProvidersProvider.overrideWith((ref) async => providers),
    ],
  );

  const oidc = OAuthProvider(name: 'oidc', displayName: 'Anmeldung der Gruppe');

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

  group('signing in through an identity provider', () {
    testWidgets('no button at all on an instance that has no provider', (
      tester,
    ) async {
      // The default. A button that leads nowhere is worse than no button: it is
      // the first thing a reader tries.
      await pump(tester);
      await tester.pumpAndSettle();
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.text(de.authOrSeparator), findsNothing);
    });

    testWidgets('one button per provider, labelled as the operator named it', (
      tester,
    ) async {
      // Not the provider ID: "oidc" means nothing to somebody who was told to
      // use "die Anmeldung der Gruppe".
      await pump(
        tester,
        serverInfo: info(oauth2: const ['oidc']),
        providers: const [oidc],
      );
      await tester.pumpAndSettle();

      expect(
        find.text(de.authContinueWith('Anmeldung der Gruppe')),
        findsOneWidget,
      );
    });

    testWidgets('the separator appears only when there are two ways in', (
      tester,
    ) async {
      await pump(
        tester,
        serverInfo: info(password: false, oauth2: const ['oidc']),
        providers: const [oidc],
      );
      await tester.pumpAndSettle();

      // Password off: the form, its button and the separator are all gone, and
      // the provider is the whole screen.
      expect(find.text(de.authOrSeparator), findsNothing);
      expect(find.text(de.authSignInAction), findsNothing);
      expect(
        find.widgetWithText(TextFormField, de.authEmailLabel),
        findsNothing,
      );
      expect(
        find.text(de.authContinueWith('Anmeldung der Gruppe')),
        findsOneWidget,
      );
    });

    testWidgets('a tap starts the flow and passes the scopes the server '
        'prescribed', (tester) async {
      // Without them a generic OIDC provider never sends the groups claim, and
      // everybody lands as a guest however carefully the mapping was set up.
      when(
        () => auth.signInWithOAuth2Code(
          any(),
          redirectUrl: any(named: 'redirectUrl'),
          authenticate: any(named: 'authenticate'),
          scopes: any(named: 'scopes'),
        ),
      ).thenAnswer((_) async => user());
      await pump(
        tester,
        serverInfo: info(
          oauth2: const ['oidc'],
          oauth2Scopes: const {
            'oidc': ['openid', 'groups'],
          },
        ),
        providers: const [oidc],
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(de.authContinueWith('Anmeldung der Gruppe')));
      // Pumped, not settled: a SUCCESSFUL sign-in leaves the screen busy on
      // purpose — the router's gate is what moves next, and the spinner it
      // leaves behind never settles.
      await tester.pump();
      await tester.pump();

      final scopes =
          verify(
                () => auth.signInWithOAuth2Code(
                  'oidc',
                  redirectUrl: any(named: 'redirectUrl'),
                  authenticate: any(named: 'authenticate'),
                  scopes: captureAny(named: 'scopes'),
                ),
              ).captured.single
              as List<String>;
      expect(scopes, ['openid', 'groups']);
    });

    testWidgets('a refused account is told so, not offered a retry', (
      tester,
    ) async {
      // The provisioning hook's 403 for somebody outside the allowed groups:
      // the identity provider knows them, this instance does not admit them,
      // and there is nothing for them to try differently.
      when(
        () => auth.signInWithOAuth2Code(
          any(),
          redirectUrl: any(named: 'redirectUrl'),
          authenticate: any(named: 'authenticate'),
          scopes: any(named: 'scopes'),
        ),
      ).thenThrow(
        const RepositoryException(
          'refused',
          kind: RepositoryErrorKind.unauthorized,
        ),
      );
      await pump(
        tester,
        serverInfo: info(oauth2: const ['oidc']),
        providers: const [oidc],
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(de.authContinueWith('Anmeldung der Gruppe')));
      await tester.pumpAndSettle();

      expect(find.text(de.authOauthRefused), findsOneWidget);
      expect(find.text(de.authOauthFailed), findsNothing);
    });

    testWidgets('a DEACTIVATED account is told so here too, and signed back '
        'out', (tester) async {
      // A departed member keeps their account — deactivation is how access
      // ends — so their sign-in AT THE PROVIDER goes on working. Without this
      // they would land in the app and meet a 403 on every read instead of a
      // sentence.
      when(
        () => auth.signInWithOAuth2Code(
          any(),
          redirectUrl: any(named: 'redirectUrl'),
          authenticate: any(named: 'authenticate'),
          scopes: any(named: 'scopes'),
        ),
      ).thenAnswer((_) async => user(active: false));
      await pump(
        tester,
        serverInfo: info(oauth2: const ['oidc']),
        providers: const [oidc],
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(de.authContinueWith('Anmeldung der Gruppe')));
      await tester.pumpAndSettle();

      expect(find.text(de.authErrorDeactivated), findsOneWidget);
      verify(() => auth.signOut()).called(1);
    });

    testWidgets('an abandoned flow can be escaped without restarting the app', (
      tester,
    ) async {
      // A browser that was simply closed leaves a future that never completes.
      // Without a way out the screen stays locked for good.
      final never = Completer<AppUser>();
      addTearDown(() => never.complete(user()));
      when(
        () => auth.signInWithOAuth2Code(
          any(),
          redirectUrl: any(named: 'redirectUrl'),
          authenticate: any(named: 'authenticate'),
          scopes: any(named: 'scopes'),
        ),
      ).thenAnswer((_) => never.future);
      await pump(
        tester,
        serverInfo: info(oauth2: const ['oidc']),
        providers: const [oidc],
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(de.authContinueWith('Anmeldung der Gruppe')));
      await tester.pump();

      expect(find.text(de.authOauthWaiting), findsOneWidget);
      await tester.tap(find.text(de.actionCancel));
      await tester.pumpAndSettle();

      expect(find.text(de.authOauthWaiting), findsNothing);
      // Unlocked, not errored: nothing went wrong, the person changed their
      // mind.
      expect(find.text(de.authOauthFailed), findsNothing);
      final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
      expect(button.onPressed, isNotNull);
    });
  });
}
