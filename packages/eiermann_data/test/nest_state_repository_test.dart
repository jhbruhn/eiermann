import 'package:eiermann_data/eiermann_data.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

class _MockPb extends Mock implements PocketBase {}

class _MockService extends Mock implements RecordService {}

void main() {
  late _MockPb pb;
  late _MockService states;
  late NestStateRepository repo;

  setUp(() {
    pb = _MockPb();
    states = _MockService();
    when(() => pb.collection('nest_state')).thenReturn(states);
    when(
      () => pb.filter(any(), any()),
    ).thenAnswer((i) => i.positionalArguments.first as String);
    when(
      () => states.getList(
        page: any(named: 'page'),
        perPage: any(named: 'perPage'),
        skipTotal: any(named: 'skipTotal'),
        filter: any(named: 'filter'),
        sort: any(named: 'sort'),
        expand: any(named: 'expand'),
        fields: any(named: 'fields'),
      ),
    ).thenAnswer(
      (_) async => ResultList(
        items: [
          RecordModel({'id': 'n1', 'label': 'N1', 'area': 'a1', 'urgency': 3}),
        ],
      ),
    );
    repo = NestStateRepository(pb);
  });

  List<dynamic> captured() => verify(
    () => states.getList(
      page: any(named: 'page'),
      perPage: any(named: 'perPage'),
      skipTotal: any(named: 'skipTotal'),
      filter: captureAny(named: 'filter'),
      sort: captureAny(named: 'sort'),
      expand: any(named: 'expand'),
      fields: any(named: 'fields'),
    ),
  ).captured;

  test('forSpot reads one building, loudest first then by label', () async {
    // The whole point of the denormalised `spot` on a nest: this is one table
    // and no join, and it is the block that has to stand on the dossier.
    final rows = await repo.forSpot('s1');

    expect(rows.single.label, 'N1');
    final call = captured();
    expect(call[0], 'spot = {:spot}');
    expect(call[1], 'urgency,label');
  });

  test('forArea reads the pins of one photo, in the same order', () async {
    await repo.forArea('a1');

    final call = captured();
    expect(call[0], 'area = {:area}');
    expect(call[1], 'urgency,label');
  });

  test('there is no write path at all', () {
    // A view cannot be written, and the TYPE is what says so: `create` is not
    // declared on a read-only repository, so a write here is a compile error
    // rather than the 400 the server would answer.
    expect(repo, isNot(isA<Repository<Object>>()));
  });
}
