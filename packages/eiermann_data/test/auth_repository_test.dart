import 'package:eiermann_data/eiermann_data.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

class _MockPb extends Mock implements PocketBase {}

class _MockService extends Mock implements RecordService {}

/// One provider as `/api/collections/users/auth-methods` returns it: the
/// `authURL` ends on a bare `redirect_uri=` and the `state` is already baked
/// into it, which is what the code flow relies on.
AuthMethodProvider provider({
  String name = 'oidc',
  String displayName = 'Anmeldung der Gruppe',
  String state = 'st4te',
  String scope = 'openid',
}) => AuthMethodProvider(
  name: name,
  displayName: displayName,
  state: state,
  codeVerifier: 'v3rifier',
  authURL:
      'https://id.example.org/authorize?state=$state&scope=$scope'
      '&redirect_uri=',
);

RecordAuth authOf(String id) => RecordAuth(
  token: 't',
  record: RecordModel({'id': id, 'email': 'feld@eiermann.test'}),
);

void main() {
  late _MockPb pb;
  late _MockService users;

  setUp(() {
    pb = _MockPb();
    users = _MockService();
    when(() => pb.collection('users')).thenReturn(users);
  });

  void serverOffers(List<AuthMethodProvider> providers) {
    when(users.listAuthMethods).thenAnswer(
      (_) async => AuthMethodsList(
        oauth2: AuthMethodOAuth2(enabled: true, providers: providers),
      ),
    );
  }

  group('oauthProviders', () {
    test('maps name and display name', () async {
      serverOffers([provider()]);

      final list = await AuthRepository(pb).oauthProviders();

      expect(list.single.name, 'oidc');
      expect(list.single.displayName, 'Anmeldung der Gruppe');
    });

    test(
      'falls back to the name when the operator configured no label',
      () async {
        // Otherwise the button renders with no text at all.
        serverOffers([provider(displayName: '')]);

        final list = await AuthRepository(pb).oauthProviders();

        expect(list.single.displayName, 'oidc');
      },
    );

    test('is empty on a password-only instance', () async {
      serverOffers([]);

      expect(await AuthRepository(pb).oauthProviders(), isEmpty);
    });
  });

  group('signInWithOAuth2', () {
    test('passes the scopes through and maps the record', () async {
      when(
        () => users.authWithOAuth2(any(), any(), scopes: any(named: 'scopes')),
      ).thenAnswer((_) async => authOf('u1'));

      final user = await AuthRepository(pb).signInWithOAuth2(
        'oidc',
        (_) async {},
        scopes: const ['openid', 'groups'],
      );

      expect(user.id, 'u1');
      final scopes =
          verify(
                () => users.authWithOAuth2(
                  'oidc',
                  any(),
                  scopes: captureAny(named: 'scopes'),
                ),
              ).captured.single
              as List<String>;
      expect(scopes, ['openid', 'groups']);
    });

    test('translates a client failure', () async {
      when(
        () => users.authWithOAuth2(any(), any(), scopes: any(named: 'scopes')),
      ).thenThrow(ClientException(statusCode: 403));

      await expectLater(
        AuthRepository(pb).signInWithOAuth2('oidc', (_) async {}),
        throwsA(
          isA<RepositoryException>().having(
            (e) => e.kind,
            'kind',
            RepositoryErrorKind.unauthorized,
          ),
        ),
      );
    });
  });

  group('signInWithOAuth2Code', () {
    setUp(() {
      when(
        () => users.authWithOAuth2Code(any(), any(), any(), any()),
      ).thenAnswer((_) async => authOf('u2'));
    });

    test('appends the redirect to the authorization URL and exchanges the '
        'code', () async {
      serverOffers([provider()]);
      Uri? opened;

      final user = await AuthRepository(pb).signInWithOAuth2Code(
        'oidc',
        redirectUrl: 'eiermann://oauth-callback',
        authenticate: (url) async {
          opened = url;
          return 'eiermann://oauth-callback?state=st4te&code=c0de';
        },
      );

      expect(user.id, 'u2');
      // The bare `redirect_uri=` is what points the provider at the APP rather
      // than at PocketBase's realtime relay.
      expect(
        opened!.queryParameters['redirect_uri'],
        'eiermann://oauth-callback',
      );
      verify(
        () => users.authWithOAuth2Code(
          'oidc',
          'c0de',
          'v3rifier',
          'eiermann://oauth-callback',
        ),
      ).called(1);
    });

    test('replaces the scope rather than adding to it', () async {
      // PocketBase's own `scope` is overwritten, so the caller must name every
      // scope it needs — `openid` included.
      serverOffers([provider()]);
      Uri? opened;

      await AuthRepository(pb).signInWithOAuth2Code(
        'oidc',
        redirectUrl: 'eiermann://oauth-callback',
        authenticate: (url) async {
          opened = url;
          return 'eiermann://oauth-callback?state=st4te&code=c0de';
        },
        scopes: const ['openid', 'groups'],
      );

      expect(opened!.queryParameters['scope'], 'openid groups');
    });

    test('refuses a callback whose state does not match', () async {
      // The CSRF guard: without it an attacker's callback would be exchanged
      // for a session on this device.
      serverOffers([provider()]);

      await expectLater(
        AuthRepository(pb).signInWithOAuth2Code(
          'oidc',
          redirectUrl: 'eiermann://oauth-callback',
          authenticate: (_) async =>
              'eiermann://oauth-callback?state=someone-elses&code=c0de',
        ),
        throwsA(isA<RepositoryException>()),
      );
      verifyNever(() => users.authWithOAuth2Code(any(), any(), any(), any()));
    });

    test("reports the provider's own error instead of exchanging", () async {
      serverOffers([provider()]);

      await expectLater(
        AuthRepository(pb).signInWithOAuth2Code(
          'oidc',
          redirectUrl: 'eiermann://oauth-callback',
          authenticate: (_) async =>
              'eiermann://oauth-callback?state=st4te&error=access_denied',
        ),
        throwsA(isA<RepositoryException>()),
      );
      verifyNever(() => users.authWithOAuth2Code(any(), any(), any(), any()));
    });

    test('refuses a callback with no code at all', () async {
      serverOffers([provider()]);

      await expectLater(
        AuthRepository(pb).signInWithOAuth2Code(
          'oidc',
          redirectUrl: 'eiermann://oauth-callback',
          authenticate: (_) async => 'eiermann://oauth-callback?state=st4te',
        ),
        throwsA(isA<RepositoryException>()),
      );
      verifyNever(() => users.authWithOAuth2Code(any(), any(), any(), any()));
    });

    test('names an unknown provider rather than opening a browser', () async {
      serverOffers([provider()]);
      var opened = false;

      await expectLater(
        AuthRepository(pb).signInWithOAuth2Code(
          'google',
          redirectUrl: 'eiermann://oauth-callback',
          authenticate: (_) async {
            opened = true;
            return '';
          },
        ),
        throwsA(isA<RepositoryException>()),
      );
      expect(opened, isFalse);
    });
  });
}
