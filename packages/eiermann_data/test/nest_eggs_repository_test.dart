import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

class _MockPb extends Mock implements PocketBase {}

class _MockService extends Mock implements RecordService {}

void main() {
  late _MockPb pb;
  late _MockService eggs;
  late NestEggsRepository repo;

  setUp(() {
    pb = _MockPb();
    eggs = _MockService();
    when(() => pb.collection('nest_eggs')).thenReturn(eggs);
    when(
      () => pb.filter(any(), any()),
    ).thenAnswer((i) => i.positionalArguments.first as String);
    when(
      () => eggs.getList(
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
          RecordModel({
            'id': 'e0',
            'nest': 'n1',
            'slot_index': 0,
            'kind': 'dummy',
            'since': '2026-08-01 09:00:00.000Z',
          }),
        ],
      ),
    );
    repo = NestEggsRepository(pb);
  });

  test('forNest reads one nest in SLOT order', () async {
    // The row on screen is the row in the nest: the endpoint writes real eggs
    // first and then dummies, and re-sorting by date here would make the same
    // clutch look different from one visit to the next.
    final rows = await repo.forNest('n1');

    expect(rows.single.kind, EggKind.dummy);
    final captured = verify(
      () => eggs.getList(
        page: any(named: 'page'),
        perPage: any(named: 'perPage'),
        skipTotal: any(named: 'skipTotal'),
        filter: captureAny(named: 'filter'),
        sort: captureAny(named: 'sort'),
        expand: any(named: 'expand'),
        fields: any(named: 'fields'),
      ),
    ).captured;
    expect(captured[0], contains('nest = {:nest}'));
    expect(captured[1], 'slot_index');
  });

  test('the type has no writers at all', () {
    // Not a convention: `nest_eggs` has no create, update or delete rule. The
    // only writer is the transactional visit endpoint, which rewrites the whole
    // row set from the outcome of a check — so a write from a screen is a
    // COMPILE error here rather than the 400 it would otherwise be.
    expect(repo, isA<PbReadOnlyRepository<NestEgg>>());
    expect(repo, isNot(isA<Repository<NestEgg>>()));
  });
}
