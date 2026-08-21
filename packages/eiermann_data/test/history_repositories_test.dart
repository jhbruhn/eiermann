import 'package:eiermann_data/eiermann_data.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

class _MockPb extends Mock implements PocketBase {}

class _MockService extends Mock implements RecordService {}

void main() {
  late _MockPb pb;
  late _MockService service;

  /// The captured (filter, sort, expand) of the single list call.
  List<dynamic> captured() => verify(
    () => service.getList(
      page: any(named: 'page'),
      perPage: any(named: 'perPage'),
      skipTotal: any(named: 'skipTotal'),
      filter: captureAny(named: 'filter'),
      sort: captureAny(named: 'sort'),
      expand: captureAny(named: 'expand'),
      fields: any(named: 'fields'),
    ),
  ).captured;

  setUp(() {
    pb = _MockPb();
    service = _MockService();
    when(() => pb.collection(any())).thenReturn(service);
    // The real `filter` binds params into the expression; this stands in for
    // it well enough to assert on what was ASKED, which is the contract here.
    when(() => pb.filter(any(), any())).thenAnswer((i) {
      var expr = i.positionalArguments.first as String;
      final params =
          (i.positionalArguments.length > 1
                  ? i.positionalArguments[1]
                  : const <String, dynamic>{})
              as Map<String, dynamic>;
      for (final entry in params.entries) {
        expr = expr.replaceAll('{:${entry.key}}', "'${entry.value}'");
      }
      return expr;
    });
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
    ).thenAnswer((_) async => ResultList(items: []));
  });

  group('VisitHistoryRepository', () {
    test('pages a building by the date the visit HAPPENED', () async {
      // Not by `created`. The flow holds everything in memory until the last
      // button, so a visit recorded in the evening is a visit made that
      // afternoon — and a chronology ordered by the write date would put a
      // late-entered morning visit after an afternoon one, with nothing on
      // screen to explain why.
      await VisitHistoryRepository(pb).pageForSpot('s1');

      final call = captured();
      expect(call[0], "spot = 's1'");
      // The id breaks the tie, and it is part of the KEYSET contract: two
      // visits on the same day need a stable second key or paging can skip one.
      expect(call[1], '-visited_at,-id');
    });

    test('there is no write path at all', () {
      // `visits` has no create rule: the only writer is the transactional
      // endpoint, and this type is what says a screen cannot go round it.
      expect(
        VisitHistoryRepository(pb),
        isNot(isA<Repository<Object>>()),
      );
    });
  });

  group('NestChecksRepository', () {
    test('reads a whole page of visits in ONE request', () async {
      // PocketBase has no `IN`, so set membership is an OR chain — and the
      // point of building it is that a chronology of twenty visits costs one
      // request rather than twenty.
      await NestChecksRepository(pb).forVisits(['v1', 'v2', 'v3']);

      final call = captured();
      expect(call[0], "visit = 'v1' || visit = 'v2' || visit = 'v3'");
      expect(call[1], 'checked_at,nest');
      // The nest LABEL, resolved server-side so this stays one request: an id
      // with no label next to it is a bug in this app.
      expect(call[2], 'nest');
    });

    test('no visits means no request', () async {
      // An empty OR chain is an empty expression, which matches EVERYTHING —
      // so the empty case must not reach the server at all.
      final rows = await NestChecksRepository(pb).forVisits([]);

      expect(rows, isEmpty);
      verifyNever(
        () => service.getList(
          page: any(named: 'page'),
          perPage: any(named: 'perPage'),
          skipTotal: any(named: 'skipTotal'),
          filter: any(named: 'filter'),
          sort: any(named: 'sort'),
          expand: any(named: 'expand'),
          fields: any(named: 'fields'),
        ),
      );
    });
  });

  group('FindingsRepository', () {
    test('reads a whole page of visits in ONE request', () async {
      await FindingsRepository(pb).forVisits(['v1', 'v2']);

      final call = captured();
      expect(call[0], "visit = 'v1' || visit = 'v2'");
      expect(call[1], 'found_at');
    });

    test('no visits means no request', () async {
      expect(await FindingsRepository(pb).forVisits([]), isEmpty);
    });

    test('the org-wide list names the building', () async {
      // It spans buildings, and the building is the first thing somebody needs
      // from it. Without the expand the row would carry an id.
      await FindingsRepository(pb).pageRecent();

      final call = captured();
      expect(call[1], '-found_at,-id');
      expect(call[2], 'spot,nest');
    });

    test('the count is a SERVER-side count, over a window', () async {
      // One number is the whole answer, so pulling every row over the wire to
      // call `.length` on it is the same request with a payload nobody reads.
      when(
        () => service.getList(
          page: any(named: 'page'),
          perPage: any(named: 'perPage'),
          skipTotal: any(named: 'skipTotal'),
          filter: any(named: 'filter'),
          fields: any(named: 'fields'),
        ),
      ).thenAnswer((_) async => ResultList(items: [], totalItems: 7));

      final count = await FindingsRepository(
        pb,
      ).countSince(DateTime.utc(2026, 7, 22));

      expect(count, 7);
      final asked = verify(
        () => service.getList(
          page: any(named: 'page'),
          perPage: any(named: 'perPage'),
          skipTotal: captureAny(named: 'skipTotal'),
          filter: captureAny(named: 'filter'),
          fields: captureAny(named: 'fields'),
        ),
      ).captured;
      // `skipTotal: false` is the whole request: the count IS the answer.
      expect(asked[0], isFalse);
      expect(asked[1], contains('found_at >='));
      expect(asked[2], 'id');
    });
  });
}
