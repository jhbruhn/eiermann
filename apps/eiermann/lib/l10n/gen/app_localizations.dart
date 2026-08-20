// dart format off
// coverage:ignore-file
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_de.dart';
import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale) : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('de'),
    Locale('en')
  ];

  /// The app name shown in the task switcher.
  ///
  /// In de, this message translates to:
  /// **'Eiermann'**
  String get appTitle;

  /// No description provided for @actionCancel.
  ///
  /// In de, this message translates to:
  /// **'Abbrechen'**
  String get actionCancel;

  /// No description provided for @actionRetry.
  ///
  /// In de, this message translates to:
  /// **'Erneut versuchen'**
  String get actionRetry;

  /// No description provided for @actionSave.
  ///
  /// In de, this message translates to:
  /// **'Speichern'**
  String get actionSave;

  /// No description provided for @discardChangesTitle.
  ///
  /// In de, this message translates to:
  /// **'Änderungen verwerfen?'**
  String get discardChangesTitle;

  /// No description provided for @discardChangesMessage.
  ///
  /// In de, this message translates to:
  /// **'Deine ungespeicherten Änderungen gehen verloren.'**
  String get discardChangesMessage;

  /// No description provided for @discardConfirm.
  ///
  /// In de, this message translates to:
  /// **'Verwerfen'**
  String get discardConfirm;

  /// No description provided for @discardKeepEditing.
  ///
  /// In de, this message translates to:
  /// **'Weiter bearbeiten'**
  String get discardKeepEditing;

  /// No description provided for @loadingLabel.
  ///
  /// In de, this message translates to:
  /// **'Wird geladen…'**
  String get loadingLabel;

  /// No description provided for @emptyGeneric.
  ///
  /// In de, this message translates to:
  /// **'Hier ist noch nichts'**
  String get emptyGeneric;

  /// No description provided for @offlineNotice.
  ///
  /// In de, this message translates to:
  /// **'Offline – keine Änderungen möglich'**
  String get offlineNotice;

  /// No description provided for @errorGenericTitle.
  ///
  /// In de, this message translates to:
  /// **'Etwas ist schiefgelaufen'**
  String get errorGenericTitle;

  /// No description provided for @errorOffline.
  ///
  /// In de, this message translates to:
  /// **'Du bist offline – prüfe deine Verbindung und versuche es erneut. Deine Eingabe bleibt erhalten.'**
  String get errorOffline;

  /// No description provided for @errorUnauthorized.
  ///
  /// In de, this message translates to:
  /// **'Dazu bist du nicht berechtigt'**
  String get errorUnauthorized;

  /// No description provided for @errorNotFound.
  ///
  /// In de, this message translates to:
  /// **'Nicht gefunden'**
  String get errorNotFound;

  /// No description provided for @errorValidation.
  ///
  /// In de, this message translates to:
  /// **'Die Daten konnten nicht gespeichert werden'**
  String get errorValidation;

  /// Shown for a write whose outcome cannot be known. Must NOT read as 'not reached, try again' — a blind retry can duplicate data.
  ///
  /// In de, this message translates to:
  /// **'Der Server hat nicht rechtzeitig geantwortet – deine Änderung wurde möglicherweise trotzdem gespeichert. Prüfe die Liste, bevor du es erneut versuchst, um Duplikate zu vermeiden.'**
  String get errorUnknownOutcome;

  /// No description provided for @errorLoadFailed.
  ///
  /// In de, this message translates to:
  /// **'Konnte nicht geladen werden – keine Verbindung zum Server'**
  String get errorLoadFailed;

  /// No description provided for @fieldRequired.
  ///
  /// In de, this message translates to:
  /// **'Dieses Feld ist erforderlich'**
  String get fieldRequired;

  /// No description provided for @fieldInvalidEmail.
  ///
  /// In de, this message translates to:
  /// **'Bitte eine gültige E-Mail-Adresse eingeben'**
  String get fieldInvalidEmail;

  /// No description provided for @fieldInvalidUrl.
  ///
  /// In de, this message translates to:
  /// **'Bitte eine gültige URL eingeben'**
  String get fieldInvalidUrl;

  /// No description provided for @fieldMinLength.
  ///
  /// In de, this message translates to:
  /// **'Mindestens {min} Zeichen erforderlich'**
  String fieldMinLength(int min);

  /// No description provided for @fieldIntMin.
  ///
  /// In de, this message translates to:
  /// **'Bitte eine Zahl von mindestens {min} eingeben'**
  String fieldIntMin(int min);

  /// No description provided for @photoAddAction.
  ///
  /// In de, this message translates to:
  /// **'Fotos hinzufügen'**
  String get photoAddAction;

  /// No description provided for @photoCaptureAction.
  ///
  /// In de, this message translates to:
  /// **'Foto aufnehmen'**
  String get photoCaptureAction;

  /// No description provided for @imageCropTitle.
  ///
  /// In de, this message translates to:
  /// **'Ausschnitt wählen'**
  String get imageCropTitle;

  /// No description provided for @imageCropFailed.
  ///
  /// In de, this message translates to:
  /// **'Bild konnte nicht zugeschnitten werden.'**
  String get imageCropFailed;

  /// No description provided for @imagePrevious.
  ///
  /// In de, this message translates to:
  /// **'Vorheriges Bild'**
  String get imagePrevious;

  /// No description provided for @imageNext.
  ///
  /// In de, this message translates to:
  /// **'Nächstes Bild'**
  String get imageNext;

  /// No description provided for @imageShareAction.
  ///
  /// In de, this message translates to:
  /// **'Teilen'**
  String get imageShareAction;

  /// No description provided for @imageShareFailed.
  ///
  /// In de, this message translates to:
  /// **'Bild konnte nicht geteilt werden.'**
  String get imageShareFailed;

  /// No description provided for @setupTitle.
  ///
  /// In de, this message translates to:
  /// **'Server einrichten'**
  String get setupTitle;

  /// No description provided for @setupExplanation.
  ///
  /// In de, this message translates to:
  /// **'Eiermann verbindet sich mit dem Server deiner Organisation. Gib die Adresse ein, die du bekommen hast.'**
  String get setupExplanation;

  /// No description provided for @setupUrlLabel.
  ///
  /// In de, this message translates to:
  /// **'Serveradresse'**
  String get setupUrlLabel;

  /// No description provided for @setupUrlHint.
  ///
  /// In de, this message translates to:
  /// **'z. B. tauben.example.org'**
  String get setupUrlHint;

  /// No description provided for @setupConnectAction.
  ///
  /// In de, this message translates to:
  /// **'Verbinden'**
  String get setupConnectAction;

  /// No description provided for @setupErrorInvalidUrl.
  ///
  /// In de, this message translates to:
  /// **'Das sieht nicht wie eine Adresse aus'**
  String get setupErrorInvalidUrl;

  /// No description provided for @setupErrorUnreachable.
  ///
  /// In de, this message translates to:
  /// **'Der Server ist nicht erreichbar. Prüfe die Adresse und deine Verbindung.'**
  String get setupErrorUnreachable;

  /// No description provided for @setupErrorWrongService.
  ///
  /// In de, this message translates to:
  /// **'Da antwortet etwas, aber es ist kein Eiermann-Server.'**
  String get setupErrorWrongService;

  /// Shown when an explicit http:// URL is given for a non-loopback host.
  ///
  /// In de, this message translates to:
  /// **'Diese Adresse ist unverschlüsselt (http). Dein Passwort würde im Klartext übertragen — bitte eine https-Adresse verwenden.'**
  String get setupErrorInsecure;

  /// No description provided for @setupChangeServerAction.
  ///
  /// In de, this message translates to:
  /// **'Anderen Server verwenden'**
  String get setupChangeServerAction;

  /// No description provided for @authSignInTitle.
  ///
  /// In de, this message translates to:
  /// **'Anmelden'**
  String get authSignInTitle;

  /// No description provided for @authEmailLabel.
  ///
  /// In de, this message translates to:
  /// **'E-Mail'**
  String get authEmailLabel;

  /// No description provided for @authPasswordLabel.
  ///
  /// In de, this message translates to:
  /// **'Passwort'**
  String get authPasswordLabel;

  /// No description provided for @authSignInAction.
  ///
  /// In de, this message translates to:
  /// **'Anmelden'**
  String get authSignInAction;

  /// No description provided for @authSignOutAction.
  ///
  /// In de, this message translates to:
  /// **'Abmelden'**
  String get authSignOutAction;

  /// No description provided for @authSignOutConfirm.
  ///
  /// In de, this message translates to:
  /// **'Möchtest du dich wirklich abmelden?'**
  String get authSignOutConfirm;

  /// No description provided for @authForgotPasswordAction.
  ///
  /// In de, this message translates to:
  /// **'Passwort vergessen?'**
  String get authForgotPasswordAction;

  /// No description provided for @authResetSentTitle.
  ///
  /// In de, this message translates to:
  /// **'E-Mail unterwegs'**
  String get authResetSentTitle;

  /// Deliberately does not confirm whether the account exists — that would let anyone enumerate the team's addresses.
  ///
  /// In de, this message translates to:
  /// **'Wenn zu dieser Adresse ein Konto gehört, ist eine E-Mail zum Zurücksetzen auf dem Weg.'**
  String get authResetSentMessage;

  /// No description provided for @authErrorInvalidCredentials.
  ///
  /// In de, this message translates to:
  /// **'E-Mail oder Passwort stimmt nicht'**
  String get authErrorInvalidCredentials;

  /// No description provided for @authErrorDeactivated.
  ///
  /// In de, this message translates to:
  /// **'Dieses Konto ist deaktiviert. Wende dich an die Koordination.'**
  String get authErrorDeactivated;

  /// No description provided for @authVersionClientTooOld.
  ///
  /// In de, this message translates to:
  /// **'Diese App ist zu alt für den Server. Bitte aktualisiere die App.'**
  String get authVersionClientTooOld;

  /// Names the OPERATOR, not the user: telling this user to update their app would be a dead end, because their app is already the newer of the two.
  ///
  /// In de, this message translates to:
  /// **'Der Server ist zu alt für diese App. Bitte wende dich an die Person, die den Server betreibt.'**
  String get authVersionServerTooOld;
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['de', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {


  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de': return AppLocalizationsDe();
    case 'en': return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.'
  );
}
