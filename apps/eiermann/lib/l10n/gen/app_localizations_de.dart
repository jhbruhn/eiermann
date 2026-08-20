// dart format off
// coverage:ignore-file

// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class AppLocalizationsDe extends AppLocalizations {
  AppLocalizationsDe([String locale = 'de']) : super(locale);

  @override
  String get appTitle => 'Eiermann';

  @override
  String get actionCancel => 'Abbrechen';

  @override
  String get actionRetry => 'Erneut versuchen';

  @override
  String get actionSave => 'Speichern';

  @override
  String get discardChangesTitle => 'Änderungen verwerfen?';

  @override
  String get discardChangesMessage => 'Deine ungespeicherten Änderungen gehen verloren.';

  @override
  String get discardConfirm => 'Verwerfen';

  @override
  String get discardKeepEditing => 'Weiter bearbeiten';

  @override
  String get loadingLabel => 'Wird geladen…';

  @override
  String get emptyGeneric => 'Hier ist noch nichts';

  @override
  String get offlineNotice => 'Offline – keine Änderungen möglich';

  @override
  String get errorGenericTitle => 'Etwas ist schiefgelaufen';

  @override
  String get errorOffline => 'Du bist offline – prüfe deine Verbindung und versuche es erneut. Deine Eingabe bleibt erhalten.';

  @override
  String get errorUnauthorized => 'Dazu bist du nicht berechtigt';

  @override
  String get errorNotFound => 'Nicht gefunden';

  @override
  String get errorValidation => 'Die Daten konnten nicht gespeichert werden';

  @override
  String get errorUnknownOutcome => 'Der Server hat nicht rechtzeitig geantwortet – deine Änderung wurde möglicherweise trotzdem gespeichert. Prüfe die Liste, bevor du es erneut versuchst, um Duplikate zu vermeiden.';

  @override
  String get errorLoadFailed => 'Konnte nicht geladen werden – keine Verbindung zum Server';

  @override
  String get fieldRequired => 'Dieses Feld ist erforderlich';

  @override
  String get fieldInvalidEmail => 'Bitte eine gültige E-Mail-Adresse eingeben';

  @override
  String get fieldInvalidUrl => 'Bitte eine gültige URL eingeben';

  @override
  String fieldMinLength(int min) {
    return 'Mindestens $min Zeichen erforderlich';
  }

  @override
  String fieldIntMin(int min) {
    return 'Bitte eine Zahl von mindestens $min eingeben';
  }

  @override
  String get photoAddAction => 'Fotos hinzufügen';

  @override
  String get photoCaptureAction => 'Foto aufnehmen';

  @override
  String get imageCropTitle => 'Ausschnitt wählen';

  @override
  String get imageCropFailed => 'Bild konnte nicht zugeschnitten werden.';

  @override
  String get imagePrevious => 'Vorheriges Bild';

  @override
  String get imageNext => 'Nächstes Bild';

  @override
  String get imageShareAction => 'Teilen';

  @override
  String get imageShareFailed => 'Bild konnte nicht geteilt werden.';

  @override
  String get setupTitle => 'Server einrichten';

  @override
  String get setupExplanation => 'Eiermann verbindet sich mit dem Server deiner Organisation. Gib die Adresse ein, die du bekommen hast.';

  @override
  String get setupUrlLabel => 'Serveradresse';

  @override
  String get setupUrlHint => 'z. B. tauben.example.org';

  @override
  String get setupConnectAction => 'Verbinden';

  @override
  String get setupErrorInvalidUrl => 'Das sieht nicht wie eine Adresse aus';

  @override
  String get setupErrorUnreachable => 'Der Server ist nicht erreichbar. Prüfe die Adresse und deine Verbindung.';

  @override
  String get setupErrorWrongService => 'Da antwortet etwas, aber es ist kein Eiermann-Server.';

  @override
  String get setupErrorInsecure => 'Diese Adresse ist unverschlüsselt (http). Dein Passwort würde im Klartext übertragen — bitte eine https-Adresse verwenden.';

  @override
  String get setupChangeServerAction => 'Anderen Server verwenden';

  @override
  String get authSignInTitle => 'Anmelden';

  @override
  String get authEmailLabel => 'E-Mail';

  @override
  String get authPasswordLabel => 'Passwort';

  @override
  String get authSignInAction => 'Anmelden';

  @override
  String get authSignOutAction => 'Abmelden';

  @override
  String get authSignOutConfirm => 'Möchtest du dich wirklich abmelden?';

  @override
  String get authForgotPasswordAction => 'Passwort vergessen?';

  @override
  String get authResetSentTitle => 'E-Mail unterwegs';

  @override
  String get authResetSentMessage => 'Wenn zu dieser Adresse ein Konto gehört, ist eine E-Mail zum Zurücksetzen auf dem Weg.';

  @override
  String get authErrorInvalidCredentials => 'E-Mail oder Passwort stimmt nicht';

  @override
  String get authErrorDeactivated => 'Dieses Konto ist deaktiviert. Wende dich an die Koordination.';

  @override
  String get authVersionClientTooOld => 'Diese App ist zu alt für den Server. Bitte aktualisiere die App.';

  @override
  String get authVersionServerTooOld => 'Der Server ist zu alt für diese App. Bitte wende dich an die Person, die den Server betreibt.';
}
