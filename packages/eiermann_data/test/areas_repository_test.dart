import 'dart:typed_data';

import 'package:eiermann_data/eiermann_data.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

class _MockPb extends Mock implements PocketBase {}

class _MockService extends Mock implements RecordService {}

void main() {
  late _MockPb pb;
  late _MockService areas;
  late AreasRepository repo;

  setUp(() {
    pb = _MockPb();
    areas = _MockService();
    when(() => pb.collection('areas')).thenReturn(areas);
    when(
      () => pb.filter(any(), any()),
    ).thenAnswer((i) => i.positionalArguments.first as String);
    when(
      () => pb.buildURL(any(), any()),
    ).thenAnswer((i) => Uri.parse('http://pb.test${i.positionalArguments[0]}'));
    repo = AreasRepository(pb);
  });

  RecordModel record(String id, {String name = 'Dachboden Nord'}) =>
      RecordModel({'id': id, 'name': name, 'spot': 's1'});

  group('forSpot', () {
    test('asks for one Spot and sorts by the walking order', () async {
      // Physical order first, because somebody walks it: ground floor, then
      // the attic. Alphabetical would scatter the route somebody actually
      // walks; `name` only breaks the tie.
      when(
        () => areas.getList(
          page: any(named: 'page'),
          perPage: any(named: 'perPage'),
          skipTotal: any(named: 'skipTotal'),
          filter: any(named: 'filter'),
          sort: any(named: 'sort'),
          expand: any(named: 'expand'),
          fields: any(named: 'fields'),
        ),
      ).thenAnswer((_) async => ResultList(items: [record('a1')]));

      final rows = await repo.forSpot('s1');

      expect(rows.single.name, 'Dachboden Nord');
      final call = verify(
        () => areas.getList(
          page: any(named: 'page'),
          perPage: any(named: 'perPage'),
          skipTotal: any(named: 'skipTotal'),
          filter: captureAny(named: 'filter'),
          sort: captureAny(named: 'sort'),
          expand: any(named: 'expand'),
          fields: any(named: 'fields'),
        ),
      ).captured;
      expect(call[0], 'spot = {:spot}');
      expect(call[1], 'sort_index,name');
    });
  });

  group('body', () {
    test('a create carries the parent and the org', () {
      final body = AreasRepository.body(
        name: 'Dachboden Nord',
        spot: 's1',
        org: 'org1',
      );

      expect(body['name'], 'Dachboden Nord');
      expect(body['spot'], 's1');
      expect(body['org'], 'org1');
    });

    test('an update carries NEITHER — both are frozen on the stored row', () {
      // An update rule resolves a plain field reference against the STORED
      // record, so a re-parenting write would be authorised against the old
      // Spot while landing on the new one — and it would take the Bereich's
      // nests and their whole check history with it.
      final body = AreasRepository.body(name: 'Dachboden Nord umbenannt');

      expect(body.containsKey('spot'), isFalse);
      expect(body.containsKey('org'), isFalse);
    });

    test('never sends photo, previous_photo or pins_need_review', () {
      // The file goes as a multipart part; the other two belong to the
      // replacement hook. A client that raised the flag itself could raise it
      // without keeping the old photo, and then the review pass has nothing to
      // compare against.
      final body = AreasRepository.body(
        name: 'Dachboden Nord',
        note: 'Zugang über die Luke',
        sortIndex: 1,
        spot: 's1',
      );

      expect(body.containsKey('photo'), isFalse);
      expect(body.containsKey('previous_photo'), isFalse);
      expect(body.containsKey('pins_need_review'), isFalse);
    });

    test('no sort_index is OMITTED rather than sent as zero', () {
      // Zero is a real position — the first one. Sending it for "no opinion"
      // would put every unordered Bereich in front of the one somebody put
      // there on purpose.
      expect(
        AreasRepository.body(name: 'Dachboden Nord').containsKey('sort_index'),
        isFalse,
      );
    });
  });

  group('the photo', () {
    test('goes up as a multipart part named photo', () async {
      when(
        () => areas.update(
          any(),
          body: any(named: 'body'),
          files: any(named: 'files'),
        ),
      ).thenAnswer((_) async => record('a1'));

      await repo.updateWithFiles('a1', const {}, [
        http.MultipartFile.fromBytes(
          'photo',
          Uint8List.fromList([1, 2, 3]),
          filename: 'dachboden.jpg',
        ),
      ]);

      final files =
          verify(
                () => areas.update(
                  'a1',
                  body: any(named: 'body'),
                  files: captureAny(named: 'files'),
                ),
              ).captured.single
              as List<http.MultipartFile>;
      expect(files.single.field, 'photo');
      expect(files.single.filename, 'dachboden.jpg');
    });

    test('its URL is built token-free, for the cache to sign', () async {
      // `areas.photo` is protected — the inside of somebody's building — and
      // the token is appended at download time by the protected-file cache. A
      // token baked into the URL would become the cache key and expire with it,
      // re-downloading the same bytes every two minutes.
      final url = repo.fileUrl('a1', 'dachboden.jpg', thumb: '1200x1200');

      expect(url.path, '/api/files/areas/a1/dachboden.jpg');
      expect(url.toString(), isNot(contains('token')));
    });
  });
}
