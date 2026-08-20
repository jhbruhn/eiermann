// dart format off
// coverage:ignore-file

// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Eiermann';

  @override
  String get actionCancel => 'Cancel';

  @override
  String get actionRetry => 'Try again';

  @override
  String get actionSave => 'Save';

  @override
  String get discardChangesTitle => 'Discard changes?';

  @override
  String get discardChangesMessage => 'Your unsaved changes will be lost.';

  @override
  String get discardConfirm => 'Discard';

  @override
  String get discardKeepEditing => 'Keep editing';

  @override
  String get loadingLabel => 'Loading…';

  @override
  String get emptyGeneric => 'Nothing here yet';

  @override
  String get offlineNotice => 'Offline – changes are not possible';

  @override
  String get errorGenericTitle => 'Something went wrong';

  @override
  String get errorOffline => 'You are offline – check your connection and try again. Your entry is kept.';

  @override
  String get errorUnauthorized => 'You are not allowed to do that';

  @override
  String get errorNotFound => 'Not found';

  @override
  String get errorValidation => 'The data could not be saved';

  @override
  String get errorUnknownOutcome => 'The server did not answer in time – your change may have been saved anyway. Check the list before trying again, to avoid duplicates.';

  @override
  String get errorLoadFailed => 'Could not load – no connection to the server';

  @override
  String get fieldRequired => 'This field is required';

  @override
  String get fieldInvalidEmail => 'Please enter a valid email address';

  @override
  String get fieldInvalidUrl => 'Please enter a valid URL';

  @override
  String fieldMinLength(int min) {
    return 'At least $min characters required';
  }

  @override
  String fieldIntMin(int min) {
    return 'Please enter a number of at least $min';
  }

  @override
  String get photoAddAction => 'Add photos';

  @override
  String get photoCaptureAction => 'Take a photo';

  @override
  String get imageCropTitle => 'Choose a crop';

  @override
  String get imageCropFailed => 'The image could not be cropped.';

  @override
  String get imagePrevious => 'Previous image';

  @override
  String get imageNext => 'Next image';

  @override
  String get imageShareAction => 'Share';

  @override
  String get imageShareFailed => 'The image could not be shared.';

  @override
  String get setupTitle => 'Set up the server';

  @override
  String get setupExplanation => 'Eiermann connects to your organisation\'s server. Enter the address you were given.';

  @override
  String get setupUrlLabel => 'Server address';

  @override
  String get setupUrlHint => 'e.g. pigeons.example.org';

  @override
  String get setupConnectAction => 'Connect';

  @override
  String get setupErrorInvalidUrl => 'That does not look like an address';

  @override
  String get setupErrorUnreachable => 'The server cannot be reached. Check the address and your connection.';

  @override
  String get setupErrorWrongService => 'Something answered there, but it is not an Eiermann server.';

  @override
  String get setupErrorInsecure => 'This address is unencrypted (http). Your password would travel in the clear — please use an https address.';

  @override
  String get setupChangeServerAction => 'Use a different server';

  @override
  String get authSignInTitle => 'Sign in';

  @override
  String get authEmailLabel => 'Email';

  @override
  String get authPasswordLabel => 'Password';

  @override
  String get authSignInAction => 'Sign in';

  @override
  String get authSignOutAction => 'Sign out';

  @override
  String get authSignOutConfirm => 'Do you really want to sign out?';

  @override
  String get authForgotPasswordAction => 'Forgot your password?';

  @override
  String get authResetSentTitle => 'Email on its way';

  @override
  String get authResetSentMessage => 'If an account belongs to this address, a reset email is on its way.';

  @override
  String get authErrorInvalidCredentials => 'That email or password is not right';

  @override
  String get authErrorDeactivated => 'This account is deactivated. Please contact the coordination.';

  @override
  String get authVersionClientTooOld => 'This app is too old for the server. Please update the app.';

  @override
  String get authVersionServerTooOld => 'The server is too old for this app. Please contact whoever runs the server.';
}
