import 'package:eiermann/features/auth/oauth_popup_io.dart'
    if (dart.library.js_interop) 'package:eiermann/features/auth/oauth_popup_web.dart'
    as impl;

/// A browser window opened **synchronously inside the tap**, to be pointed at
/// the provider once the URL exists.
///
/// Safari — and every browser on iOS, which is Safari underneath — blocks
/// `window.open` unless it runs in the call stack of a user gesture.
/// PocketBase's realtime flow produces the authorization URL only after two
/// awaits, so a window opened at that point reads as an unsolicited popup and
/// is refused: the sign-in page simply never appears. Opening a blank window up
/// front and merely NAVIGATING it later sidesteps that, because pointing an
/// already-open window somewhere needs no gesture.
///
/// Off the web this is nothing: native has no popup blocker to appease.
abstract interface class OAuthPopup {
  /// Points the pre-opened window at [url].
  void navigateTo(Uri url);

  /// Closes the window if it is still open — for a flow that failed or was
  /// abandoned before the provider's own redirect page closed it.
  void closeIfOpen();
}

/// Opens a blank popup now, or returns null off the web — and also when the
/// browser refused even inside the gesture, so the caller can fall back to an
/// ordinary launch.
OAuthPopup? openBlankOAuthPopup() => impl.openBlankOAuthPopup();
