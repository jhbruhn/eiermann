import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

class _MockPb extends Mock implements PocketBase {}

/// One complete `/api/eiermann/stats` body, as the route sends it.
Map<String, dynamic> body() => {
  'period': {'year': 2026, 'month': 3},
  'totals': {
    'visits': 4,
    'visitsChecked': 3,
    'visitsSkipped': 1,
    'spotsVisited': 2,
    'checks': 7,
    'removedReal': 6,
    'addedDummy': 6,
    'findings': 2,
    'accessRate': 0.75,
    'fullSwapRate': 0.5,
    'eggsPerCheckedVisit': 2,
  },
  'series': {
    'kind': 'day',
    'points': [
      {'key': 1, 'visits': 0, 'removed': 0, 'dummies': 0},
      {'key': 2, 'visits': 2, 'removed': 4, 'dummies': 4},
    ],
    'previous': {
      'year': 2025,
      'month': 3,
      'points': [
        {'key': 2, 'visits': 1, 'removed': 1, 'dummies': 1},
      ],
    },
  },
  'checkStates': [
    {'state': 'swapped', 'count': 2},
    {'state': 'partial', 'count': 2},
    // A state this build has no name for. Counted, never dropped: the census
    // has to keep summing to `checks`.
    {'state': 'levitated', 'count': 3},
  ],
  'findingKinds': [
    {'kind': 'dead_bird', 'count': 2},
  ],
  'findingSpecies': [
    {'label': 'Dohle', 'count': 1},
  ],
  'skipReasons': [
    {'reason': 'no_key', 'count': 1},
  ],
  'addresses': [
    {'label': 'Mühlenstraße 5, 26121 Oldenburg', 'count': 3},
  ],
  'visitYears': [2026, 2025],
  'spots': {
    'total': 4,
    'phases': [
      {'phase': 'active', 'count': 3},
      {'phase': 'prospect', 'count': 1},
    ],
    'prospectStages': [
      {'stage': 'owner_spoken', 'count': 1},
    ],
  },
};

void main() {
  late _MockPb pb;
  late StatsRepository repo;

  setUp(() {
    pb = _MockPb();
    repo = StatsRepository(pb);
  });

  void answerWith(Map<String, dynamic> response) {
    when(
      () => pb.send<Map<String, dynamic>>(
        any(),
        method: any(named: 'method'),
        query: any(named: 'query'),
        body: any(named: 'body'),
        headers: any(named: 'headers'),
        files: any(named: 'files'),
      ),
    ).thenAnswer((_) async => response);
  }

  Map<String, dynamic> sentQuery() {
    final call = verify(
      () => pb.send<Map<String, dynamic>>(
        captureAny(),
        method: any(named: 'method'),
        query: captureAny(named: 'query'),
        body: any(named: 'body'),
        headers: any(named: 'headers'),
        files: any(named: 'files'),
      ),
    );
    // No `.called(1)`: mocktail marks the call verified as soon as this
    // matches, and a second check over a consumed call reports "no matching
    // calls" — which reads as the request never having been made.
    return call.captured[1] as Map<String, dynamic>;
  }

  test('reads the route and parses every block of it', () async {
    answerWith(body());
    final stats = await repo.fetch(year: 2026, month: 3, tzOffsetMinutes: 60);

    expect(stats.year, 2026);
    expect(stats.month, 3);
    expect(stats.visits, 4);
    expect(stats.visitsSkipped, 1);
    expect(stats.spotsVisited, 2);
    expect(stats.eggsRemoved, 6);
    expect(stats.dummiesPlaced, 6);
    expect(stats.accessRate, 0.75);
    expect(stats.fullSwapRate, 0.5);
    expect(stats.series.kind, SeriesBucket.day);
    expect(stats.series.points.length, 2);
    expect(stats.series.points[1].removed, 4);
    expect(stats.series.hasPrevious, isTrue);
    expect(stats.series.previousYear, 2025);
    expect(stats.findingKinds.single.value, FindingKind.deadBird);
    expect(stats.findingSpecies.single.label, 'Dohle');
    expect(stats.skipReasons.single.value, SkipReason.noKey);
    expect(stats.addresses.single.count, 3);
    expect(stats.visitYears, [2026, 2025]);
    expect(stats.spots.total, 4);
    expect(stats.spots.phases.first.value, SpotPhase.active);
    expect(stats.spots.prospectStages.single.value, ProspectStage.ownerSpoken);
  });

  test('a wire value this build cannot name is counted, not dropped', () {
    // Otherwise the census stops summing to `checks`, and a reader comparing
    // the rows against the total finds a gap with no explanation on screen.
    final stats = OrgStatistics.fromResponse(body());
    expect(stats.checkStates.length, 3);
    final unknown = stats.checkStates.last;
    expect(unknown.value, isNull);
    expect(unknown.count, 3);
    expect(
      stats.checkStates.fold<int>(0, (sum, c) => sum + c.count),
      stats.checks,
    );
  });

  test('a month is never sent without its year', () async {
    // "März" alone names no period, and the route refuses it with a code. A
    // client that sent it would turn a UI slip into a server error.
    answerWith(body());
    await repo.fetch(month: 3, tzOffsetMinutes: 60);
    // Captured ONCE: a verify consumes the call it matched, so a second
    // sentQuery() would report that no request was ever made.
    final query = sentQuery();
    expect(query.containsKey('month'), isFalse);
    expect(query.containsKey('year'), isFalse);
  });

  test('the caller states its own UTC offset', () async {
    // The server has no timezone database, so it cannot resolve a zone name.
    // This offset is what decides which side of New Year a late-evening visit
    // falls on — and sending it is what makes this screen and the printed
    // report agree about what a year is.
    answerWith(body());
    await repo.fetch(year: 2026, tzOffsetMinutes: 120);
    final query = sentQuery();
    expect(query['tzOffsetMinutes'], '120');
    expect(query['year'], '2026');
  });

  test('a body missing a block reads as absent, not as a throw', () async {
    // A server one minor version older simply omits a key. A screen showing
    // nothing for a figure it was not sent is a better failure than one that
    // cannot render at all.
    answerWith({
      'period': <String, dynamic>{},
      'totals': <String, dynamic>{},
    });
    final stats = await repo.fetch();
    expect(stats.isEmpty, isTrue);
    expect(stats.accessRate, isNull, reason: 'a rate is null, never 0');
    expect(stats.fullSwapRate, isNull);
    expect(stats.series.kind, SeriesBucket.year);
    expect(stats.series.hasPrevious, isFalse);
    expect(stats.spots.isEmpty, isTrue);
    expect(stats.visitYears, isEmpty);
  });

  test('an all-zero comparison series is no comparison', () async {
    // The server omits `previous` when the period a year earlier held nothing,
    // and the chart must not draw a legend for a series of noughts.
    final withoutPrevious = body();
    // Removed rather than set to null: the map is typed `Map<String, dynamic>`
    // through the literal above but its nested one is inferred non-nullable.
    (withoutPrevious['series'] as Map).remove('previous');
    answerWith(withoutPrevious);
    final stats = await repo.fetch(year: 2026);
    expect(stats.series.hasPrevious, isFalse);
    expect(stats.series.previousPoints, isEmpty);
  });

  test('a failure arrives as a RepositoryException', () async {
    when(
      () => pb.send<Map<String, dynamic>>(
        any(),
        method: any(named: 'method'),
        query: any(named: 'query'),
        body: any(named: 'body'),
        headers: any(named: 'headers'),
        files: any(named: 'files'),
      ),
    ).thenThrow(ClientException(statusCode: 403));
    await expectLater(repo.fetch(), throwsA(isA<RepositoryException>()));
  });
}
