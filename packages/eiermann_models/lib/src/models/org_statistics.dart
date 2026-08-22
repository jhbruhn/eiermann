import 'package:eiermann_models/src/enums.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:zugvogel_core/zugvogel_core.dart';

/// One labelled count in a breakdown.
///
/// [label] is either free text a volunteer typed (an Artbezeichnung, an
/// address) or a WIRE value the caller resolves through the enum's own label
/// helper. Which of the two it is depends on the list, and every field below
/// says so — a wire value rendered straight into the UI is how `not_reachable`
/// ends up on a screen.
@immutable
class StatCount {
  const StatCount(this.label, this.count);

  final String label;
  final int count;
}

/// A count keyed by an enum value this build may not know.
///
/// A null [value] counts rows whose wire value this app version cannot name.
/// Counted rather than dropped, because the census has to reconcile with the
/// total beside it — a breakdown that quietly loses a bucket is a breakdown a
/// reader cannot check.
@immutable
class EnumCount<T> {
  const EnumCount(this.value, this.count);

  final T? value;
  final int count;
}

/// What one point of a [VisitSeries] counts, following the selected period: a
/// day of the selected month, a month of the selected year, or a whole calendar
/// year when the period is "all time".
enum SeriesBucket implements WireEnum {
  day('day'),
  month('month'),
  year('year');

  const SeriesBucket(this.wire);

  @override
  final String wire;

  static SeriesBucket? fromWire(Object? v) => wireEnum(values, v);
}

/// One bucket of the series: [key] is the day of the month (1–31), the month
/// (1–12) or the calendar year, per [VisitSeries.kind].
///
/// Three numbers and not one, because "wie viel wurde getan" has two honest
/// answers and they move differently: [visits] is how often somebody went, and
/// [removed] is what came of it. A month of six visits that found empty nests
/// is a good month, and a chart of eggs alone would draw it as a bad one.
@immutable
class SeriesPoint {
  const SeriesPoint(
    this.key, {
    this.visits = 0,
    this.removed = 0,
    this.dummies = 0,
  });

  final int key;
  final int visits;

  /// Real eggs removed in this bucket.
  final int removed;

  /// Dummies placed in this bucket.
  final int dummies;
}

/// The work over time, with the same period a year earlier behind it.
///
/// The server emits every bucket of the period, zeros included, so the series
/// reads as a period rather than as a list of the buckets that happened to have
/// visits — a February nobody went out in is a fact about the year.
@immutable
class VisitSeries {
  const VisitSeries({
    required this.kind,
    this.points = const [],
    this.previousYear,
    this.previousMonth,
    this.previousPoints = const [],
  });

  final SeriesBucket kind;
  final List<SeriesPoint> points;

  /// The comparison year, or null when there is nothing to compare against —
  /// an all-time period, or a previous period with no visits at all (an
  /// all-zero comparison is noise, not a comparison).
  final int? previousYear;

  /// The comparison month when a month is selected: always the SAME month a
  /// year earlier, never the month before. Seasonality is the question a group
  /// asks of these figures — pigeons breed on a calendar — and the month before
  /// answers a different one, badly, because half the difference is the season
  /// turning.
  final int? previousMonth;

  /// The comparison period's buckets, aligned with [points] by key.
  final List<SeriesPoint> previousPoints;

  bool get hasPrevious => previousYear != null && previousPoints.isNotEmpty;
}

/// What the org has access to RIGHT NOW: how many buildings per phase, and how
/// far the running Erkundungen have got.
///
/// The one block of [OrgStatistics] that is NOT period-scoped. It answers "how
/// far does our access reach", which the selected year has no bearing on —
/// render it as a standing figure, because putting it inside a period's card
/// would describe it as something it is not.
@immutable
class SpotStanding {
  const SpotStanding({
    this.total = 0,
    this.phases = const [],
    this.prospectStages = const [],
  });

  /// Every Spot on record, in any phase.
  final int total;

  /// Phase → count. Keyed by the enum, so the reader's build names it.
  final List<EnumCount<SpotPhase>> phases;

  /// Stage → count, over the Spots that are STILL Erkundungen. A permitted
  /// building has moved on to `active` and counting its old stage here would
  /// report the funnel as twice as full as it is.
  final List<EnumCount<ProspectStage>> prospectStages;

  bool get isEmpty => total == 0;
}

/// The org's reporting figures for one period, as computed by
/// `GET /api/eiermann/stats` (`pb_hooks/stats.pb.js`).
///
/// Everything here is a server-side aggregate: the app never sees the rows
/// behind it, and that is the point twice over. A monthly series with a
/// comparison year behind it spans more history than a handset should be
/// pulling, and these are the same rows the printed report reads — so the
/// screen and the PDF agree by construction rather than by two implementations
/// staying in step.
///
/// Every field is defaulted rather than required: a server one minor version
/// older simply omits a key, and a screen that shows nothing for a figure it
/// was not sent is a better failure than one that throws.
@immutable
class OrgStatistics {
  const OrgStatistics({
    this.year,
    this.month,
    this.visits = 0,
    this.visitsChecked = 0,
    this.visitsSkipped = 0,
    this.spotsVisited = 0,
    this.checks = 0,
    this.eggsRemoved = 0,
    this.dummiesPlaced = 0,
    this.findings = 0,
    this.accessRate,
    this.fullSwapRate,
    this.eggsPerCheckedVisit,
    this.series = const VisitSeries(kind: SeriesBucket.year),
    this.checkStates = const [],
    this.findingKinds = const [],
    this.findingSpecies = const [],
    this.skipReasons = const [],
    this.addresses = const [],
    this.visitYears = const [],
    this.spots = const SpotStanding(),
  });

  /// Parses the route's body.
  ///
  /// `fromResponse` and not `fromJson`: freezed reads that name and emits
  /// `_$XFromJson` calls even in a package that does not run json_serializable,
  /// and the failure is a missing symbol in generated code that says nothing
  /// about the naming rule. This class is hand-written for the same reason — it
  /// is one route's response, not a record.
  factory OrgStatistics.fromResponse(Map<String, dynamic> json) {
    final period = json['period'];
    final totals = json['totals'];
    final t = totals is Map ? totals : const <String, dynamic>{};

    List<StatCount> counts(Object? raw) => [
      for (final e in raw is List ? raw : const [])
        if (e is Map && e['label'] is String)
          StatCount(e['label'] as String, _int(e['count'])),
    ];
    List<EnumCount<T>> enums<T>(
      Object? raw,
      String key,
      T? Function(Object?) fromWire,
    ) => [
      for (final e in raw is List ? raw : const [])
        if (e is Map) EnumCount<T>(fromWire(e[key]), _int(e['count'])),
    ];

    final spots = json['spots'];
    return OrgStatistics(
      year: period is Map ? _intOrNull(period['year']) : null,
      month: period is Map ? _intOrNull(period['month']) : null,
      visits: _int(t['visits']),
      visitsChecked: _int(t['visitsChecked']),
      visitsSkipped: _int(t['visitsSkipped']),
      spotsVisited: _int(t['spotsVisited']),
      checks: _int(t['checks']),
      eggsRemoved: _int(t['removedReal']),
      dummiesPlaced: _int(t['addedDummy']),
      findings: _int(t['findings']),
      accessRate: _doubleOrNull(t['accessRate']),
      fullSwapRate: _doubleOrNull(t['fullSwapRate']),
      eggsPerCheckedVisit: _doubleOrNull(t['eggsPerCheckedVisit']),
      series: _series(json['series']),
      checkStates: enums(json['checkStates'], 'state', CheckState.fromWire),
      findingKinds: enums(json['findingKinds'], 'kind', FindingKind.fromWire),
      findingSpecies: counts(json['findingSpecies']),
      skipReasons: enums(json['skipReasons'], 'reason', SkipReason.fromWire),
      addresses: counts(json['addresses']),
      visitYears: [
        for (final e
            in json['visitYears'] is List
                ? json['visitYears'] as List
                : const <Object?>[])
          ?_intOrNull(e),
      ],
      spots: SpotStanding(
        total: spots is Map ? _int(spots['total']) : 0,
        phases: spots is Map
            ? enums(spots['phases'], 'phase', SpotPhase.fromWire)
            : const [],
        prospectStages: spots is Map
            ? enums(spots['prospectStages'], 'stage', ProspectStage.fromWire)
            : const [],
      ),
    );
  }

  static VisitSeries _series(Object? raw) {
    if (raw is! Map) return const VisitSeries(kind: SeriesBucket.year);
    final previous = raw['previous'];
    return VisitSeries(
      // An unknown bucket kind reads as a year series: the chart then labels
      // its keys as the numbers they are, instead of as month names it guessed.
      kind: SeriesBucket.fromWire(raw['kind']) ?? SeriesBucket.year,
      points: _points(raw['points']),
      previousYear: previous is Map ? _intOrNull(previous['year']) : null,
      previousMonth: previous is Map ? _intOrNull(previous['month']) : null,
      previousPoints: previous is Map ? _points(previous['points']) : const [],
    );
  }

  static List<SeriesPoint> _points(Object? raw) => [
    for (final e in raw is List ? raw : const [])
      if (e is Map)
        if (_intOrNull(e['key']) case final key?)
          SeriesPoint(
            key,
            visits: _int(e['visits']),
            removed: _int(e['removed']),
            dummies: _int(e['dummies']),
          ),
  ];

  static int _int(Object? v) => v is num ? v.toInt() : 0;
  static int? _intOrNull(Object? v) => v is num ? v.toInt() : null;
  static double? _doubleOrNull(Object? v) => v is num ? v.toDouble() : null;

  /// The selected calendar year, or null for every visit on record.
  final int? year;

  /// The selected month within [year] (1–12), or null for the whole year.
  final int? month;

  /// Trips made in the period, checked and skipped together.
  final int visits;

  /// Trips where the team got in and looked at nests.
  final int visitsChecked;

  /// Trips where nobody was there, the key was missing, the way was blocked.
  /// A document, not an observation — and the figure a request for a key is
  /// argued with.
  final int visitsSkipped;

  /// Distinct buildings visited in the period.
  final int spotsVisited;

  /// Nest checks recorded across those trips.
  final int checks;

  /// Real eggs removed.
  final int eggsRemoved;

  /// Dummies placed.
  final int dummiesPlaced;

  /// Funde recorded: dead birds, chicks, other species, structural changes.
  final int findings;

  /// Share of trips that got in, 0–1, or null while none has been made.
  ///
  /// Over ALL trips, because the question is how often the team gets in — a
  /// skipped visit is what makes the figure interesting, so it belongs in the
  /// denominator.
  final double? accessRate;

  /// Share of the clutches actually ENCOUNTERED that were swapped clean, 0–1,
  /// or null while none has been found.
  ///
  /// The denominator is `swapped + partial` and nothing else: over all checks
  /// it would sag every time the team finds more empty nests, which is when the
  /// work is going well. A figure that falls on good news is a figure people
  /// stop trusting.
  final double? fullSwapRate;

  /// Mean eggs removed per trip that got in — fractional, and over checked
  /// trips only. A trip nobody got into had no chance to remove an egg.
  final double? eggsPerCheckedVisit;

  /// The work over time, with the same period a year earlier behind it.
  final VisitSeries series;

  /// The check-state census, in the enum's declared order and complete: the
  /// counts sum to [checks], so a reader can reconcile it.
  final List<EnumCount<CheckState>> checkStates;

  /// Fund kind → count, most common first.
  final List<EnumCount<FindingKind>> findingKinds;

  /// Artbezeichnung → count over the period's Funde, most common first. FREE
  /// TEXT a volunteer typed: nothing to translate and nothing to map.
  final List<StatCount> findingSpecies;

  /// Why a trip did not become a check, most common first.
  final List<EnumCount<SkipReason>> skipReasons;

  /// Address → visits in the period, most common first. Already rendered
  /// server-side, because the report groups by the same string.
  final List<StatCount> addresses;

  /// Every calendar year with at least one visit, newest first — org-wide
  /// regardless of the selected period, because it is what the period picker
  /// offers.
  ///
  /// Only years that actually have visits: a fixed "last ten years" range would
  /// invite reporting on a year the group did not exist. The years are the
  /// caller's LOCAL ones, matching how the period's boundaries are resolved.
  final List<int> visitYears;

  /// What the org has access to right now — a STANDING figure, not a figure for
  /// [year] / [month].
  final SpotStanding spots;

  /// Whether the period holds nothing at all.
  bool get isEmpty => visits == 0;
}
