import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_data/zugvogel_data.dart';

/// Signing in, signing out, and who is signed in.
///
/// Thin on purpose: PocketBase owns the session, and this only maps its auth
/// record to [AppUser] and translates failures into the [RepositoryException]
/// the UI already knows how to render.
class AuthRepository {
  AuthRepository(this._pb);

  final PocketBase _pb;

  /// Emits whenever the session changes — sign-in, sign-out, token refresh.
  Stream<void> get changes => _pb.authStore.onChange;

  /// The signed-in user, or null.
  ///
  /// Read straight off the auth store rather than fetched: the record is
  /// already there, and a network round trip to answer "who am I" would make
  /// every cold start wait for it.
  AppUser? get currentUser {
    final record = _pb.authStore.record;
    if (record == null) return null;
    return AppUser.fromRecord(record);
  }

  bool get isSignedIn => _pb.authStore.isValid;

  /// Signs in with email and password.
  ///
  /// A deactivated account is refused by the collection's own `authRule`, which
  /// answers 400 — indistinguishable on the wire from a wrong password. That is
  /// deliberate on the server's side (it tells an attacker nothing), so the UI
  /// asks separately, after a successful sign-in, whether the account is
  /// active.
  Future<AppUser> signIn(String email, String password) async {
    try {
      final auth = await _pb
          .collection('users')
          .authWithPassword(email.trim(), password);
      return AppUser.fromRecord(auth.record);
    } on ClientException catch (e) {
      throw RepositoryException.fromClient(e);
    }
  }

  /// The OAuth2 providers this server offers, in the order to present them.
  ///
  /// Empty when none are configured. Worth reading only once `/info` has said
  /// there are any (`ServerAuthOptions.oauth2`): this call exists to learn the
  /// BUTTON LABELS, which `/info` deliberately does not carry — it is
  /// unauthenticated, and a display name is the operator's wording, not a
  /// capability.
  Future<List<OAuthProvider>> oauthProviders() async {
    try {
      final methods = await _pb.collection('users').listAuthMethods();
      return methods.oauth2.providers
          .map(
            (p) => OAuthProvider(
              name: p.name,
              // A provider with no configured display name would otherwise
              // render a button with no label at all.
              displayName: p.displayName.isNotEmpty ? p.displayName : p.name,
            ),
          )
          .toList(growable: false);
    } on ClientException catch (e) {
      throw RepositoryException.fromClient(e);
    }
  }

  /// Signs in through [provider] using PocketBase's all-in-one flow: it hands
  /// [openUrl] the provider's authorization URL, and the sign-in completes over
  /// PocketBase's realtime channel — no redirect handling on this side.
  ///
  /// **Web only.** That channel has to stay connected while the person is on
  /// the provider's page, which does not hold on a phone: Android backgrounds
  /// the app the moment the browser takes over, the connection drops, and the
  /// redirect is never delivered — the sign-in then "fails" for no reason the
  /// reader can see. Use [signInWithOAuth2Code] there.
  ///
  /// [scopes] REPLACES the `scope` parameter rather than adding to it, so it
  /// must name every scope the flow needs, `openid` included. Empty leaves
  /// PocketBase's own scopes alone — which is right until the server asks for
  /// more, and it says so through `/info`'s `oauth2Scopes`: a generic OIDC
  /// provider releases the groups claim the provisioning hook maps roles from
  /// only to a request that asked for it.
  Future<AppUser> signInWithOAuth2(
    String provider,
    Future<void> Function(Uri url) openUrl, {
    List<String> scopes = const [],
  }) async {
    try {
      final auth = await _pb
          .collection('users')
          .authWithOAuth2(provider, openUrl, scopes: scopes);
      return AppUser.fromRecord(auth.record);
    } on ClientException catch (e) {
      throw RepositoryException.fromClient(e);
    }
  }

  /// Signs in through [provider] by exchanging an authorization code the
  /// provider delivered to [redirectUrl] — the flow that works on a phone,
  /// because a deep link arrives whether or not the app was backgrounded.
  ///
  /// [redirectUrl] must be registered with the provider as an allowed redirect
  /// URI; the app's own scheme is in `oauth_launcher.dart`. [authenticate] is
  /// handed the authorization URL, opens it, waits for the provider to come
  /// back, and returns that full callback URL — injected so this package needs
  /// no browser plugin of its own.
  ///
  /// [scopes] behaves as in [signInWithOAuth2].
  ///
  /// Throws a [RepositoryException] when the returned `state` does not match
  /// the one we sent (the CSRF guard), when the provider reports an `error`, or
  /// when no `code` comes back at all.
  Future<AppUser> signInWithOAuth2Code(
    String provider, {
    required String redirectUrl,
    required Future<String> Function(Uri authorizationUrl) authenticate,
    List<String> scopes = const [],
  }) async {
    final AuthMethodProvider configured;
    try {
      final methods = await _pb.collection('users').listAuthMethods();
      configured = methods.oauth2.providers.firstWhere(
        (p) => p.name == provider,
        // The SDK's own empty instance, so the miss is one `name.isEmpty`
        // check below rather than a StateError escaping as an unknown failure.
        orElse: AuthMethodProvider.new,
      );
    } on ClientException catch (e) {
      throw RepositoryException.fromClient(e);
    }
    if (configured.name.isEmpty) {
      throw RepositoryException('unknown OAuth2 provider "$provider"');
    }

    // `authURL` ends with a bare `redirect_uri=`; appending our deep link is
    // what points the provider back at the APP instead of at PocketBase's
    // realtime relay. The `state` already in that URL is the CSRF token to
    // match on return.
    var authorizationUrl = Uri.parse(configured.authURL + redirectUrl);
    if (scopes.isNotEmpty) {
      // No SDK helper on this path, so the same overwrite the all-in-one flow
      // does, by hand. Rebuilding the query percent-encodes `redirect_uri`,
      // which is what the SDK does too and what the provider decodes back.
      authorizationUrl = authorizationUrl.replace(
        queryParameters: {
          ...authorizationUrl.queryParameters,
          'scope': scopes.join(' '),
        },
      );
    }
    final expectedState =
        authorizationUrl.queryParameters['state'] ?? configured.state;

    final callback = Uri.parse(await authenticate(authorizationUrl));
    if (callback.queryParameters['state'] != expectedState) {
      throw const RepositoryException('OAuth2 state mismatch');
    }
    final error = callback.queryParameters['error'] ?? '';
    if (error.isNotEmpty) {
      throw RepositoryException('OAuth2 provider error: $error');
    }
    final code = callback.queryParameters['code'] ?? '';
    if (code.isEmpty) {
      throw const RepositoryException('OAuth2 redirect returned no code');
    }

    try {
      final auth = await _pb
          .collection('users')
          .authWithOAuth2Code(
            configured.name,
            code,
            configured.codeVerifier,
            redirectUrl,
          );
      return AppUser.fromRecord(auth.record);
    } on ClientException catch (e) {
      throw RepositoryException.fromClient(e);
    }
  }

  /// Re-issues the token with a fresh `exp`.
  ///
  /// A no-op when signed out. Clears the store ONLY on a 401/403 — a genuinely
  /// dead or revoked token. Any other failure (offline, server down) leaves the
  /// session alone: a transient blip must never sign somebody out.
  Future<void> refresh() async {
    if (!_pb.authStore.isValid) return;
    try {
      await _pb.collection('users').authRefresh();
    } on ClientException catch (e) {
      if (e.statusCode == 401 || e.statusCode == 403) {
        _pb.authStore.clear();
      }
      throw RepositoryException.fromClient(e);
    }
  }

  /// Asks the server to send a password-reset mail.
  ///
  /// Never reports whether the address exists — that would let anyone
  /// enumerate the team's addresses.
  Future<void> requestPasswordReset(String email) async {
    try {
      await _pb.collection('users').requestPasswordReset(email.trim());
    } on ClientException catch (e) {
      throw RepositoryException.fromClient(e);
    }
  }

  /// Edits the signed-in account's own name and phone number.
  ///
  /// Exactly those two fields, and the shape is the server's:
  /// `users.updateRule` lets a member write their own row only while `role`,
  /// `org`, `is_active` and `verified` are absent from the body. Sending one of
  /// them here would not be a privilege escalation — `main.pb.js` puts the
  /// stored value back — but it would turn a routine save into a refusal, so
  /// this method cannot spell one.
  ///
  /// Goes through the AUTH collection rather than `UsersRepository` on purpose.
  /// PocketBase's SDK notices that the updated record is the one in the auth
  /// store and saves it back, which emits on [changes] — so [currentUser], and
  /// with it every screen showing the name, follows without anybody
  /// invalidating anything.
  Future<AppUser> updateProfile({String? name, String? phone}) async {
    final me = _pb.authStore.record;
    if (me == null) {
      throw const RepositoryException(
        'not signed in',
        kind: RepositoryErrorKind.unauthorized,
      );
    }
    try {
      final updated = await _pb
          .collection('users')
          .update(
            me.id,
            // Null-aware elements: an omitted argument means "leave unchanged",
            // never "clear" — an empty string is how a caller clears a field.
            body: {'name': ?name?.trim(), 'phone': ?phone?.trim()},
          );
      return AppUser.fromRecord(updated);
    } on ClientException catch (e) {
      throw RepositoryException.fromClient(e);
    }
  }

  void signOut() => _pb.authStore.clear();
}

/// One OAuth2 provider the server offers, for rendering a sign-in button.
class OAuthProvider {
  const OAuthProvider({required this.name, required this.displayName});

  /// The PocketBase provider name (`oidc`, `google`, …) — what the sign-in
  /// methods take.
  final String name;

  /// The label to put on the button: the operator's configured display name,
  /// falling back to [name].
  final String displayName;
}
