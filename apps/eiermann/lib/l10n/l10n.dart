import 'package:eiermann/l10n/gen/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

export 'package:eiermann/l10n/gen/app_localizations.dart';

extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}

/// The locale the app falls back to when the device asks for a language we do
/// not ship: German is the design language, and every string is written in it
/// first — `app_de.arb` is the gen-l10n TEMPLATE, not a translation.
///
/// Spelled out rather than leaning on `supportedLocales.first` — gen-l10n sorts
/// that list, so German only leads it by alphabetical accident and a third
/// locale sorting ahead of `de` would silently move the fallback.
const kFallbackLocale = Locale('de');

/// Picks the app locale from the device's ordered language preferences,
/// matching on language code alone (we ship no region variants), and falling
/// back to [kFallbackLocale].
Locale resolveAppLocale(List<Locale>? deviceLocales) {
  for (final device in deviceLocales ?? const <Locale>[]) {
    for (final supported in AppLocalizations.supportedLocales) {
      if (supported.languageCode == device.languageCode) return supported;
    }
  }
  return kFallbackLocale;
}

/// This app's [ZugvogelStrings], over its own generated localizations.
///
/// Injection boundary 1 from the other side: the shared widgets carry no text
/// of their own, so every word they show is one of these. Adding a member to
/// the interface obliges this class to answer for it — which is the point, and
/// why the interface is kept small.
class EiermannStrings implements ZugvogelStrings {
  const EiermannStrings(this._l10n);

  final AppLocalizations _l10n;

  // gen-l10n generates `localeName` on AppLocalizations itself, from the
  // locale of the delegate that resolved. Declaring an ARB key of the same name
  // is a compile error in the generated file, which is a confusing place to
  // read it from — so this passes the generated one straight through.
  @override
  String get localeName => _l10n.localeName;
  @override
  String get actionCancel => _l10n.actionCancel;
  @override
  String get actionRetry => _l10n.actionRetry;
  @override
  String get actionSave => _l10n.actionSave;
  @override
  String get discardChangesTitle => _l10n.discardChangesTitle;
  @override
  String get discardChangesMessage => _l10n.discardChangesMessage;
  @override
  String get discardConfirm => _l10n.discardConfirm;
  @override
  String get discardKeepEditing => _l10n.discardKeepEditing;
  @override
  String get loadingLabel => _l10n.loadingLabel;
  @override
  String get emptyGeneric => _l10n.emptyGeneric;
  @override
  String get offlineNotice => _l10n.offlineNotice;
  @override
  String get errorGenericTitle => _l10n.errorGenericTitle;
  @override
  String get errorOffline => _l10n.errorOffline;
  @override
  String get errorUnauthorized => _l10n.errorUnauthorized;
  @override
  String get errorNotFound => _l10n.errorNotFound;
  @override
  String get errorValidation => _l10n.errorValidation;
  @override
  String get errorUnknownOutcome => _l10n.errorUnknownOutcome;
  @override
  String get errorLoadFailed => _l10n.errorLoadFailed;
  @override
  String get fieldRequired => _l10n.fieldRequired;
  @override
  String get fieldInvalidEmail => _l10n.fieldInvalidEmail;
  @override
  String get fieldInvalidUrl => _l10n.fieldInvalidUrl;
  @override
  String fieldMinLength(int min) => _l10n.fieldMinLength(min);
  @override
  String fieldIntMin(int min) => _l10n.fieldIntMin(min);
  @override
  String get photoAddAction => _l10n.photoAddAction;
  @override
  String get photoCaptureAction => _l10n.photoCaptureAction;
  @override
  String get imageCropTitle => _l10n.imageCropTitle;
  @override
  String get imageCropFailed => _l10n.imageCropFailed;
  @override
  String get imagePrevious => _l10n.imagePrevious;
  @override
  String get imageNext => _l10n.imageNext;
  @override
  String get imageShareAction => _l10n.imageShareAction;
  @override
  String get imageShareFailed => _l10n.imageShareFailed;
}
