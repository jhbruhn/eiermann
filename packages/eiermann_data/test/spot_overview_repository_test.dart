import 'package:eiermann_data/eiermann_data.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

class _MockPb extends Mock implements PocketBase {}

class _MockService extends Mock implements RecordService {}

/// The real `pb.filter`, so the tests see the expression a server would.
///
/// Copied rather than mocked away: what these tests are about is WHICH SQL the
/// keyset builds, and a mock that echoed the template back would hide the one
/// thing that matters — whether the rank is bound as a number or as a quoted
/// string.
String bindFilter(Invocation i) {
  final args = i.positionalArguments;
  var expr = args[0] as String;
  for (final param in (args[1] as Map<String, dynamic>).entries) {
    final value = param.value;
    // Mirrors pocketbase 0.24: numbers bare, everything else single-quoted
    // with its own quotes escaped. The escaping is the part under test.
    final bound = value is num || value is bool || value == null
        ? '$value'
        : "'${value.toString().replaceAll("'", r"\'")}'";
    expr = expr.replaceAll('{:${param.key}}', bound);
  }
  return expr;
}

void main() {
  late _MockPb pb;
  late _MockService service;
  late SpotOverviewRepository repo;

  setUp(() {
    pb = _MockPb();
    service = _MockService();
    when(() => pb.collection('spot_overview')).thenReturn(service);
    when(() => pb.filter(any(), any())).thenAnswer(bindFilter);
    repo = SpotOverviewRepository(pb);
  });

  RecordModel row(String id, {required int urgency, required String name}) =>
      RecordModel({
        'id': id,
        'name': name,
        'urgency': urgency,
        'contact_count': 0,
        'phase': 'active',
      });

  void stubList(ResultList<RecordModel> Function(Invocation) answer) {
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
    ).thenAnswer((i) async => answer(i));
  }

  String? capturedFilter() =>
      verify(
            () => service.getList(
              page: any(named: 'page'),
              perPage: any(named: 'perPage'),
              skipTotal: any(named: 'skipTotal'),
              filter: captureAny(named: 'filter'),
              sort: any(named: 'sort'),
              expand: any(named: 'expand'),
              fields: any(named: 'fields'),
            ),
          ).captured.last
          as String?;

  String? capturedSort() =>
      verify(
            () => service.getList(
              page: any(named: 'page'),
              perPage: any(named: 'perPage'),
              skipTotal: any(named: 'skipTotal'),
              filter: any(named: 'filter'),
              sort: captureAny(named: 'sort'),
              expand: any(named: 'expand'),
              fields: any(named: 'fields'),
            ),
          ).captured.last
          as String?;

  group('dueFirst', () {
    test('orders by urgency, then name, then id', () async {
      // The sort has to be exactly what the resume predicate compares, or a
      // page skips and repeats rows. Sorting by rank alone and tie-breaking on
      // id would page correctly and hand the reader forty overdue Spots in
      // record order, which is no order at all.
      stubList((_) => ResultList(items: [row('s1', urgency: 0, name: 'A')]));

      await repo.dueFirst();

      expect(capturedSort(), 'urgency,name,id');
    });

    test('the first page asks for no filter at all', () async {
      stubList((_) => ResultList(items: [row('s1', urgency: 0, name: 'A')]));

      await repo.dueFirst();

      expect(capturedFilter(), isNull);
    });

    test('the rank is bound as a NUMBER, never as a quoted string', () async {
      // The whole reason this repository does its own keyset. `urgency` is a
      // computed view column, so SQLite gives it no affinity and compares an
      // INTEGER against TEXT by storage class — an integer is always less than
      // a string, so `urgency > '2'` matches nothing and the list silently
      // ends after one page.
      stubList(
        (_) => ResultList(
          items: [
            for (var n = 0; n < 2; n++) row('s$n', urgency: 2, name: 'A'),
          ],
        ),
      );
      final first = await repo.dueFirst(perPage: 2);

      await repo.dueFirst(after: first.cursor, perPage: 2);

      final filter = capturedFilter()!;
      expect(filter, contains('urgency > 2'));
      expect(filter, isNot(contains("urgency > '2'")));
    });

    test('the resume predicate carries all three key columns', () async {
      stubList(
        (_) => ResultList(
          items: [
            row('s1', urgency: 2, name: 'Alt'),
            row('s2', urgency: 2, name: 'Bahn'),
          ],
        ),
      );
      final first = await repo.dueFirst(perPage: 2);

      await repo.dueFirst(after: first.cursor, perPage: 2);

      expect(
        capturedFilter(),
        '(urgency > 2 || (urgency = 2 && '
        "(name > 'Bahn' || (name = 'Bahn' && id > 's2'))))",
      );
    });

    test('a SHORT page ends the list, so nothing spins forever', () async {
      stubList((_) => ResultList(items: [row('s1', urgency: 0, name: 'A')]));

      final page = await repo.dueFirst();

      expect(page.hasMore, isFalse);
      expect(page.cursor, isNull);
    });

    test('a FULL page keeps a cursor, even if it is the last one', () async {
      // A full page might be the end too; the next call returning nothing
      // settles it, which costs one request and never stops early on a
      // boundary.
      stubList(
        (_) => ResultList(
          items: [
            row('s1', urgency: 0, name: 'Alt'),
            row('s2', urgency: 1, name: 'Bahn'),
          ],
        ),
      );

      final page = await repo.dueFirst(perPage: 2);

      expect(page.hasMore, isTrue);
      expect(
        page.cursor,
        const SpotOverviewCursor(urgency: 1, name: 'Bahn', id: 's2'),
      );
    });

    test('an empty result ends the list', () async {
      stubList((_) => ResultList(items: []));

      final page = await repo.dueFirst(perPage: 2);

      expect(page.items, isEmpty);
      expect(page.hasMore, isFalse);
    });

    test('a search term and a cursor combine into one filter', () async {
      stubList(
        (_) => ResultList(
          items: [
            row('s1', urgency: 0, name: 'Alt'),
            row('s2', urgency: 0, name: 'Bahn'),
          ],
        ),
      );
      final first = await repo.dueFirst(query: 'bahn', perPage: 2);

      await repo.dueFirst(query: 'bahn', after: first.cursor, perPage: 2);

      final filter = capturedFilter()!;
      expect(filter, contains("name ~ 'bahn'"));
      expect(filter, contains('urgency > 0'));
      expect(filter, contains(' && '));
    });

    test('one urgency rank is bound as a NUMBER too', () async {
      // Same trap as the keyset, and the tile on the dashboard is where it
      // would show: `urgency = '0'` compares TEXT against the INTEGER the view
      // computed, matches nothing, and the filtered list comes back empty while
      // the tile beside it counts three.
      stubList((_) => ResultList(items: [row('s1', urgency: 0, name: 'A')]));

      await repo.dueFirst(urgency: 0);

      final filter = capturedFilter()!;
      expect(filter, contains('urgency = 0'));
      expect(filter, isNot(contains("urgency = '0'")));
    });

    test(
      'a rank, a search term and a cursor combine into one filter',
      () async {
        stubList(
          (_) => ResultList(
            items: [
              row('s1', urgency: 0, name: 'Alt'),
              row('s2', urgency: 0, name: 'Bahn'),
            ],
          ),
        );
        final first = await repo.dueFirst(
          query: 'bahn',
          urgency: 0,
          perPage: 2,
        );

        await repo.dueFirst(
          query: 'bahn',
          urgency: 0,
          after: first.cursor,
          perPage: 2,
        );

        final filter = capturedFilter()!;
        expect(filter, contains("name ~ 'bahn'"));
        expect(filter, contains('urgency = 0'));
        // The resume predicate is still there: a filtered page has to page too,
        // and a rank that swallowed the cursor would restart at the top of the
        // rank on every scroll.
        expect(filter, contains('urgency > 0'));
      },
    );

    test('maps every row through fromRecord', () async {
      stubList(
        (_) => ResultList(
          items: [
            row('s1', urgency: 0, name: 'Alt'),
            row('s2', urgency: 6, name: 'Bahn'),
          ],
        ),
      );

      final page = await repo.dueFirst();

      expect(page.items.map((s) => s.name), ['Alt', 'Bahn']);
      expect(page.items.first.urgency, 0);
    });
  });

  group('search', () {
    test('matches the name and every address column', () async {
      stubList((_) => ResultList(items: [row('s1', urgency: 0, name: 'A')]));

      await repo.search('bahnhof');

      expect(
        capturedFilter(),
        "(name ~ 'bahnhof' || street ~ 'bahnhof' || city ~ 'bahnhof' "
        "|| postal_code ~ 'bahnhof')",
      );
    });

    test('binds the term instead of interpolating it', () async {
      // A filter expression is a query language and the term is whatever
      // somebody typed, so a quote in it has to come back ESCAPED rather than
      // closing the literal and appending a clause of its own.
      stubList((_) => ResultList(items: []));

      await repo.search("' || 1=1 || name ~ '");

      final filter = capturedFilter()!;
      expect(filter, contains(r"'\' || 1=1 || name ~ \''"));
      expect(filter, isNot(contains("'' || 1=1 ||")));
      verify(() => pb.filter(any(), any())).called(1);
    });

    test('an empty term asks for everything, unfiltered', () async {
      stubList((_) => ResultList(items: []));

      await repo.search('   ');

      expect(capturedFilter(), isNull);
    });

    test('sorts by name, because the map has no urgency order', () async {
      stubList((_) => ResultList(items: []));

      await repo.search('bahn');

      expect(capturedSort(), 'name');
    });
  });

  test('a failed read surfaces as a RepositoryException', () async {
    // The UI error states depend on the stable shape, not on the SDK's.
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
    ).thenThrow(ClientException(statusCode: 403));

    await expectLater(
      repo.dueFirst(),
      throwsA(
        isA<RepositoryException>().having(
          (e) => e.kind,
          'kind',
          RepositoryErrorKind.unauthorized,
        ),
      ),
    );
  });
}
