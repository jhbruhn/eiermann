import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

/// Where an identity provider sends somebody back to on a phone, for the
/// code-exchange flow (`AuthRepository.signInWithOAuth2Code`).
///
/// It MUST be registered with the provider as an allowed redirect URI, and the
/// Android side of it is the intent filter in
/// `android/app/src/main/AndroidManifest.xml`. iOS needs no registration —
/// `ASWebAuthenticationSession` captures the scheme itself.
///
/// The host is spelled out rather than left off so this app can gain other deep
/// links later without either of them swallowing the other's URLs.
const oauthRedirectUrl = 'eiermann://oauth-callback';

/// Opens [authorizationUrl] in an in-app browser tab and resolves with the full
/// callback URL once the provider redirects back to [oauthRedirectUrl].
///
/// The tab owns the redirect and hands the result straight back, which is the
/// whole point on a phone: unlike PocketBase's realtime flow it does not matter
/// that the OS backgrounded the app while the browser was in front.
///
/// Throws a `PlatformException` with code `CANCELED` when the person dismisses
/// the browser — which is not a failure, and the login screen treats it as one
/// of the two ordinary endings.
///
/// No options are passed, so `preferEphemeral` stays off and the provider page
/// can reuse a session the browser already holds. That is what makes single
/// sign-on feel like single sign-on.
Future<String> authenticateOAuth(Uri authorizationUrl) {
  return FlutterWebAuth2.authenticate(
    url: authorizationUrl.toString(),
    callbackUrlScheme: Uri.parse(oauthRedirectUrl).scheme,
  );
}
