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
class EiermannStrings implements ZugvogelStrings, ServerCodeStrings {
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

  /// The sentence for a refusal code a hook sent.
  ///
  /// A hook says WHICH invariant it refused; the wording is here, because the
  /// server does not know which language the reader speaks. The codes are wire
  /// values — renaming one in `app_refuse.js` is a wire change and has to be
  /// made on both sides.
  ///
  /// Not every code the backend can send needs an entry. Most refusals are
  /// pre-empted by the form that would have caused them — a required field
  /// answers before the write happens — so what lands here is the race and the
  /// rule the UI has not mirrored. An unmapped code falls back to the generic
  /// copy, which is the right outcome for something nobody can act on.
  @override
  String? serverErrorFor(String code) => switch (code) {
    'spot_phase_illegal_transition' => _l10n.serverErrorSpotPhaseIllegal,
    'spot_phase_needs_permitted' => _l10n.serverErrorSpotPhaseNeedsPermitted,
    'spot_pause_needs_reason' => _l10n.serverErrorSpotPauseNeedsReason,
    'spot_close_needs_reason' => _l10n.serverErrorSpotCloseNeedsReason,
    'nest_protected_needs_coordinator' =>
      _l10n.serverErrorNestProtectedNeedsCoordinator,
    'nest_protected_no_egg_changes' =>
      _l10n.serverErrorNestProtectedNoEggChanges,
    'nest_area_not_found' => _l10n.serverErrorNestAreaNotFound,
    // Reachable only as a race: the editor hides the pin canvas when there
    // is no photo, so this is somebody removing the photo while somebody
    // else is placing a nest on it.
    'nest_pin_needs_area_photo' => _l10n.serverErrorNestPinNeedsAreaPhoto,
    // The same invariant from the other side, and mapped although no screen
    // offers photo removal yet: the day one does, an unmapped code would put
    // generic copy on a refusal whose whole value is naming the way out.
    'area_photo_still_pinned' => _l10n.serverErrorAreaPhotoStillPinned,
    'visit_nest_foreign_spot' => _l10n.serverErrorVisitNestForeignSpot,
    'visit_nest_duplicate' => _l10n.serverErrorVisitNestDuplicate,
    'visit_eggs_do_not_balance' => _l10n.serverErrorVisitEggsDoNotBalance,
    'visit_skip_has_checks' => _l10n.serverErrorVisitSkipHasChecks,
    'visit_idempotency_key_reused' =>
      _l10n.serverErrorVisitIdempotencyKeyReused,
    // The round's own guards. `tour_run_already_finished` and
    // `visit_tour_run_finished` are the same fact reached from two sides —
    // finishing a finished round, and recording into one — and they get
    // different sentences because the reader's next move differs: one is "it is
    // already done", the other is "start a new one".
    'tour_run_already_finished' => _l10n.serverErrorTourRunAlreadyFinished,
    'visit_tour_run_finished' => _l10n.serverErrorVisitTourRunFinished,
    'tour_not_found' => _l10n.serverErrorTourNotFound,
    'tour_stop_spot_not_found' => _l10n.serverErrorTourStopSpotNotFound,
    // The rhythm numbers. Mapped even though the settings screen pre-empts each
    // of them, because that screen is not the only caller the route can ever
    // have — and a refusal about which of four fields is wrong is exactly the
    // kind that must not arrive as generic copy.
    'rhythm_base_interval_invalid' => _l10n.serverErrorRhythmBaseInterval,
    'rhythm_empty_checks_per_step_invalid' => _l10n.serverErrorRhythmPerStep,
    'rhythm_half_clutch_return_invalid' => _l10n.serverErrorRhythmHalfClutch,
    'rhythm_interval_steps_invalid' => _l10n.serverErrorRhythmSteps,
    'rhythm_interval_steps_not_ascending' =>
      _l10n.serverErrorRhythmStepsNotAscending,
    'rhythm_steps_below_base' => _l10n.serverErrorRhythmStepsBelowBase,
    _ => null,
  };
}
