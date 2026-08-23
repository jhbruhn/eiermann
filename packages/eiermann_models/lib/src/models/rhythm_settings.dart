import 'package:freezed_annotation/freezed_annotation.dart';

part 'rhythm_settings.freezed.dart';

/// The numbers every due date in this app comes out of.
///
/// They live in `organisations.settings` rather than in code so that a group
/// who finds seven days too often in winter changes a field instead of waiting
/// for a release. That is the whole reason for the JSON field, and this class
/// is the typed shape it is read and written through.
///
/// **Never parsed out of the `organisations` record.** The client has exactly
/// one channel to these numbers — `GET /api/eiermann/rhythm` — because a JSON
/// field mapped a second time is the trap that silently disabled two federfall
/// features: a value that fails to parse does not error, it falls into a
/// default, and the app then works correctly with numbers nobody chose. The
/// server decodes once, in `zv_org.js`, and answers in types.
@freezed
abstract class RhythmSettings with _$RhythmSettings {
  const factory RhythmSettings({
    /// Days until the next check of a nest that had something in it.
    required int baseIntervalDays,

    /// How many empty checks in a row it takes to climb one rung.
    required int emptyChecksPerStep,

    /// The ladder, in days. The last value is the cap and is reached rather
    /// than exceeded — a nest empty twenty times running comes back round every
    /// [intervalSteps] `.last` days forever, because something with a roof over
    /// it can always come back.
    required List<int> intervalSteps,

    /// Days until the Nachkontrolle after a Halbgelege.
    required int halfClutchReturnDays,

    /// Whether a paused Spot comes back by itself when `paused_until` passes.
    required bool pauseAutoResume,
  }) = _RhythmSettings;

  /// Parses `GET|PATCH /api/eiermann/rhythm`.
  ///
  /// Named `fromResponse` and not `fromJson`: freezed reads the name `fromJson`
  /// and emits a `_$RhythmSettingsFromJson` call, which in a freezed-only
  /// package is a missing symbol in generated code that says nothing about the
  /// naming rule.
  ///
  /// The defaults here are the server's own, restated. They are not expected to
  /// be used — the route always answers with every field filled in — but a
  /// response missing one must not produce a zero interval, which would make
  /// everything permanently overdue.
  factory RhythmSettings.fromResponse(Map<String, dynamic> json) =>
      RhythmSettings(
        baseIntervalDays: _int(json['baseIntervalDays'], 7),
        emptyChecksPerStep: _int(json['emptyChecksPerStep'], 3),
        intervalSteps: _steps(json['intervalSteps']),
        halfClutchReturnDays: _int(json['halfClutchReturnDays'], 4),
        pauseAutoResume: json['pauseAutoResume'] != false,
      );

  const RhythmSettings._();

  /// The body a PATCH sends.
  ///
  /// All five, always. The route is a partial PATCH — omitting a field keeps it
  /// — but this app's screen shows all five at once, so sending all five is
  /// what the reader saw and pressed save on. A form that submitted only what
  /// it believed had changed would be a form whose idea of "changed" is the
  /// thing that goes wrong.
  Map<String, dynamic> toBody() => {
    'baseIntervalDays': baseIntervalDays,
    'emptyChecksPerStep': emptyChecksPerStep,
    'intervalSteps': intervalSteps,
    'halfClutchReturnDays': halfClutchReturnDays,
    'pauseAutoResume': pauseAutoResume,
  };
}

int _int(Object? value, int fallback) {
  final parsed = value is num ? value.toInt() : int.tryParse('$value');
  return parsed == null || parsed < 1 ? fallback : parsed;
}

List<int> _steps(Object? value) {
  if (value is! List) return const [7, 14, 28];
  final steps = <int>[];
  for (final entry in value) {
    final parsed = entry is num ? entry.toInt() : int.tryParse('$entry');
    if (parsed != null && parsed > 0) steps.add(parsed);
  }
  // Never empty: `intervalFor` indexes into this list, and an empty ladder on
  // the server falls back to `[7]` rather than erroring. Matching that here
  // keeps the screen honest about what the rhythm would actually do.
  return steps.isEmpty ? const [7, 14, 28] : steps;
}
