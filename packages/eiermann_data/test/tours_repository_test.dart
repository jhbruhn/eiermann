import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

class _MockPb extends Mock implements PocketBase {}

class _MockService extends Mock implements RecordService {}

/// Every named argument of `getList`, so a `verify` can pin the two that matter
/// without repeating the noise at each call site.
void _stubList(_MockService service, List<RecordModel> items) {
  when(
    () => service.getList(
      page: any(named: 'page'),
      perPage: any(named: 'perPage'),
      skipTotal: any(named: 'skipTotal'),
      filter: any(named: 'filter'),
      sort: any(named: 'sort'),
      expand: any(named: 'expand'),
      fields: any(named: 'fields'),
    ),
  ).thenAnswer((_) async => ResultList(items: items));
}

void _verifyList(
  _MockService service, {
  required String? filter,
  required String? sort,
  String? expand,
}) {
  verify(
    () => service.getList(
      page: any(named: 'page'),
      perPage: any(named: 'perPage'),
      skipTotal: any(named: 'skipTotal'),
      filter: filter,
      sort: sort,
      expand: expand ?? any(named: 'expand'),
      fields: any(named: 'fields'),
    ),
  ).called(1);
}

void main() {
  late _MockPb pb;
  late _MockService tours;
  late _MockService stops;
  late _MockService runs;
  late _MockService visits;

  setUp(() {
    pb = _MockPb();
    tours = _MockService();
    stops = _MockService();
    runs = _MockService();
    visits = _MockService();
    when(() => pb.collection('tours')).thenReturn(tours);
    when(() => pb.collection('tour_spots')).thenReturn(stops);
    when(() => pb.collection('tour_runs')).thenReturn(runs);
    when(() => pb.collection('visits')).thenReturn(visits);
    when(
      () => pb.filter(any(), any()),
    ).thenAnswer((i) => i.positionalArguments.first as String);
  });

  group('ToursRepository', () {
    test(
      'active() asks for the templates still in use, in the group order',
      () {
        _stubList(tours, [
          RecordModel({'id': 't1', 'name': 'Tour 1', 'is_active': true}),
        ]);

        return ToursRepository(pb).active().then((rows) {
          expect(rows.single.name, 'Tour 1');
          _verifyList(
            tours,
            filter: 'is_active = true',
            sort: 'sort_index,name',
          );
        });
      },
    );

    test(
      'all() keeps the retired ones — they have rounds behind them',
      () async {
        _stubList(tours, [
          RecordModel({'id': 't1', 'name': 'Alt', 'is_active': false}),
        ]);

        await ToursRepository(pb).all();

        _verifyList(tours, filter: null, sort: 'sort_index,name');
      },
    );

    test('retire writes the flag and nothing else', () async {
      when(
        () => tours.update(any(), body: any(named: 'body')),
      ).thenAnswer((_) async => RecordModel({'id': 't1', 'is_active': false}));

      await ToursRepository(pb).retire('t1');

      final body =
          verify(
                () => tours.update('t1', body: captureAny(named: 'body')),
              ).captured.single
              as Map<String, dynamic>;
      expect(body, {'is_active': false});
    });

    test('the body omits org on the edit path, so the update rule passes', () {
      // An update rule resolves `org` against the STORED record: a body
      // carrying it would be authorised against the old org and land in the
      // new one.
      final body = ToursRepository.body(name: 'Tour 1');

      expect(body.containsKey('org'), isFalse);
      expect(body['is_active'], isTrue);
      // Empty, not absent: PocketBase reads a missing key as "leave it", so an
      // omitted note would silently keep the old one.
      expect(body['note'], '');
    });
  });

  group('TourStopsRepository', () {
    test('forTour reads one route in order, with the building names', () async {
      _stubList(stops, [
        RecordModel({'id': 'st1', 'tour': 't1', 'spot': 's1'}),
      ]);

      await TourStopsRepository(pb).forTour('t1');

      // The expand is the point: a request per stop is what makes an app feel
      // broken on a phone in a stairwell.
      _verifyList(
        stops,
        filter: 'tour = {:tour}',
        sort: 'sort_index,id',
        expand: 'spot',
      );
    });

    test('reorder writes only the stops whose index actually moved', () async {
      // A drag moves a row's neighbours, not the whole route. PocketBase has no
      // bulk update, so the saving grace is sending two writes instead of
      // twelve.
      when(
        () => stops.update(any(), body: any(named: 'body')),
      ).thenAnswer(
        (i) async => RecordModel({'id': i.positionalArguments.first}),
      );

      const order = [
        TourStop(id: 'a', tour: 't1', spot: 's1', sortIndex: 1),
        TourStop(id: 'b', tour: 't1', spot: 's2', sortIndex: 0),
        TourStop(id: 'c', tour: 't1', spot: 's3', sortIndex: 2),
      ];
      await TourStopsRepository(pb).reorder(order);

      verify(() => stops.update('a', body: {'sort_index': 0})).called(1);
      verify(() => stops.update('b', body: {'sort_index': 1})).called(1);
      // Already at index 2 — untouched.
      verifyNever(() => stops.update('c', body: any(named: 'body')));
    });

    test('a new stop carries its position', () {
      final body = TourStopsRepository.body(
        tour: 't1',
        spot: 's1',
        sortIndex: 3,
        org: 'org1',
      );

      expect(body, {
        'tour': 't1',
        'spot': 's1',
        'sort_index': 3,
        'org': 'org1',
      });
    });
  });

  group('TourRunsRepository', () {
    test('openFor names the person and reads the empty-string date', () async {
      // A PocketBase date that was never set stores the empty string, not null.
      _stubList(runs, [
        RecordModel({'id': 'r1', 'started_by': 'u1', 'finished_at': ''}),
      ]);

      final run = await TourRunsRepository(pb).openFor('u1');

      expect(run?.id, 'r1');
      _verifyList(
        runs,
        filter: "finished_at = '' && started_by = {:me}",
        sort: '-started_at',
      );
    });

    test('...and the newest wins when a crash left two open', () async {
      // Should not happen — the app offers resuming rather than starting — but
      // a crash between two taps could produce it, and the newest is the one
      // that matches what they just did.
      _stubList(runs, [
        RecordModel({'id': 'newest'}),
        RecordModel({'id': 'older'}),
      ]);

      final run = await TourRunsRepository(pb).openFor('u1');

      expect(run?.id, 'newest');
    });

    test('...and no open round is null, not an exception', () async {
      _stubList(runs, []);

      expect(await TourRunsRepository(pb).openFor('u1'), isNull);
    });

    test('start sends the template and the org — nothing else', () async {
      // Who started it, when, and under what name are the SERVER's: a snapshot
      // a client supplies is a snapshot that can lie, in the one direction
      // nobody could catch.
      when(
        () => runs.create(body: any(named: 'body')),
      ).thenAnswer((_) async => RecordModel({'id': 'r1'}));

      await TourRunsRepository(pb).start(tour: 't1', org: 'org1');

      final body =
          verify(
                () => runs.create(body: captureAny(named: 'body')),
              ).captured.single
              as Map<String, dynamic>;
      expect(body, {'tour': 't1', 'org': 'org1'});
    });

    test('an improvised round sends no template at all', () async {
      when(
        () => runs.create(body: any(named: 'body')),
      ).thenAnswer((_) async => RecordModel({'id': 'r1'}));

      await TourRunsRepository(pb).start(org: 'org1');

      final body =
          verify(
                () => runs.create(body: captureAny(named: 'body')),
              ).captured.single
              as Map<String, dynamic>;
      expect(body.containsKey('tour'), isFalse);
    });

    test('finish sends a timestamp — the server stamps its own', () async {
      when(() => runs.update(any(), body: any(named: 'body'))).thenAnswer(
        (_) async => RecordModel({'id': 'r1', 'finished_at': 'x'}),
      );

      await TourRunsRepository(pb).finish('r1');

      final body =
          verify(
                () => runs.update('r1', body: captureAny(named: 'body')),
              ).captured.single
              as Map<String, dynamic>;
      // Non-empty is what matters: the server would read '' as "not finished",
      // and it overwrites the value with its own clock either way.
      expect((body['finished_at'] as String).isNotEmpty, isTrue);
      expect(body.containsKey('note'), isFalse);
    });
  });

  group('VisitLogRepository', () {
    test('forRun reads the round progress in one request', () async {
      // A round's progress IS these rows — there is no per-stop table to read
      // instead. The expand carries the names of buildings the template never
      // listed.
      _stubList(visits, [
        RecordModel({'id': 'v1', 'spot': 's1', 'outcome': 'checked'}),
      ]);

      final rows = await VisitLogRepository(pb).forRun('r1');

      expect(rows.single.id, 'v1');
      _verifyList(
        visits,
        filter: 'tour_run = {:run}',
        sort: 'visited_at,id',
        expand: 'spot',
      );
    });
  });
}
