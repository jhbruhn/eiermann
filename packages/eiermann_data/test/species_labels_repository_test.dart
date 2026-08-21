import 'package:eiermann_data/eiermann_data.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

class _MockPb extends Mock implements PocketBase {}

class _MockService extends Mock implements RecordService {}

void main() {
  late _MockPb pb;
  late _MockService labels;
  late SpeciesLabelsRepository repo;

  setUp(() {
    pb = _MockPb();
    labels = _MockService();
    when(() => pb.collection('species_labels')).thenReturn(labels);
    when(
      () => pb.filter(any(), any()),
    ).thenAnswer((i) => i.positionalArguments.first as String);
    when(
      () => labels.getList(
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
            'id': 'org00000default:Dohle',
            'org': 'org00000default',
            'label': 'Dohle',
            'used_count': 7,
          }),
        ],
      ),
    );
    repo = SpeciesLabelsRepository(pb);
  });

  List<dynamic> captured() => verify(
    () => labels.getList(
      page: any(named: 'page'),
      perPage: any(named: 'perPage'),
      skipTotal: any(named: 'skipTotal'),
      filter: captureAny(named: 'filter'),
      sort: captureAny(named: 'sort'),
      expand: any(named: 'expand'),
      fields: any(named: 'fields'),
    ),
  ).captured;

  test('reads the whole vocabulary, most-used first', () async {
    // Frequency and not the alphabet: the bird somebody is about to type is far
    // more often the one they typed last week than the one that sorts first.
    // `label` breaks the ties, so the long tail is stable rather than in
    // whatever order SQLite grouped it.
    final rows = await repo.all();

    expect(rows.single.label, 'Dohle');
    expect(rows.single.usedCount, 7);
    final call = captured();
    expect(call[0], isNull, reason: 'no filter — the org scope is the rule');
    expect(call[1], '-used_count,label');
  });

  test('there is no write path at all', () {
    // The vocabulary grows by being USED. A writable list is a curated list,
    // which is the thing this view exists instead of — and the TYPE is what
    // says so: `create` is not declared on a read-only repository.
    expect(repo, isNot(isA<Repository<Object>>()));
  });
}
