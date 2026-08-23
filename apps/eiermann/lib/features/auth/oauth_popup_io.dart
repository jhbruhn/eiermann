import 'package:eiermann/features/auth/oauth_popup.dart';

/// Native has no popup blocker to appease, so nothing is pre-opened and the
/// caller uses its normal launch path.
OAuthPopup? openBlankOAuthPopup() => null;
