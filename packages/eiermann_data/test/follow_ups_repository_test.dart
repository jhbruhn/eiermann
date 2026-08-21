import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

class _MockPb extends Mock implements PocketBase {}

class _MockService extends Mock implements RecordService {}

void main() {
  late _MockPb pb;
  late _MockService followUps;
  late FollowUpsRepository repo;

  setUp(() {
    pb = _MockPb();
    followUps = _MockService();
    when(() => pb.collection('follow_ups')).thenReturn(followUps);
    when(
      () => pb.filter(any(), any()),
    ).thenAnswer((i) => i.positionalArguments.first as String);
    when(
      () => followUps.getList(
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
          RecordModel.fromJson({
            'id': 'f1',
            'spot': 's1',
            'nest': 'n3',
            'reason': 'half_clutch',
            'resolved_at': '',
            'expand': {
              'spot': {'id': 's1', 'name': 'Bahnhofstr. 12'},
              'nest': {'id': 'n3', 'label': 'N3'},
            },
          }),
        ],
      ),
    );
    repo = FollowUpsRepository(pb);
  });

  ({String? filter, String? sort, String? expand}) call() {
    final captured = verify(
      () => followUps.getList(
        page: any(named: 'page'),
        perPage: any(named: 'perPage'),
        skipTotal: any(named: 'skipTotal'),
        filter: captureAny(named: 'filter'),
        sort: captureAny(named: 'sort'),
        expand: captureAny(named: 'expand'),
        fields: any(named: 'fields'),
      ),
    ).captured;
    return (
      filter: captured[0] as String?,
      sort: captured[1] as String?,
      expand: captured[2] as String?,
    );
  }

  test('open reads the unresolved ones, earliest first', () async {
    final rows = await repo.open();

    expect(rows.single.reason, FollowUpReason.halfClutch);
    final sent = call();
    // A PocketBase date field that was never set stores the EMPTY STRING, so
    // "not resolved" is `= ''` and not `= null` — the null form matches nothing
    // and the dashboard's top block would be permanently empty.
    expect(sent.filter, contains("resolved_at = ''"));
    expect(sent.sort, 'due_at');
  });

  test('...and asks for the labels in the same request', () async {
    // The block spans every building, and an id with no label next to it is a
    // bug in this app. Expanded server-side rather than looked up afterwards:
    // still one request.
    await repo.open();

    expect(call().expand, 'spot,nest');
  });

  test('the expanded names come out as names', () async {
    final row = (await repo.open()).single;

    expect(row.spotName, 'Bahnhofstr. 12');
    expect(row.nestLabel, 'N3');
  });

  test('openForSpot scopes to one building', () async {
    await repo.openForSpot('s1');

    final sent = call();
    expect(sent.filter, contains('spot = {:spot}'));
    expect(sent.filter, contains("resolved_at = ''"));
  });

  test('a manual body cannot claim to be a Halbgelege', () async {
    // The access rule pins the reason to `manual` on create, and the resolution
    // belongs to a later CHECK: a Nachkontrolle marked done by hand is one
    // nobody carried out.
    final body = FollowUpsRepository.manualBody(
      spot: 's1',
      dueAt: DateTime.utc(2026, 8, 25),
      nest: 'n3',
      note: 'Schloss nochmal ansehen',
      org: 'o1',
    );

    expect(body['reason'], FollowUpReason.manual.wire);
    expect(body, isNot(contains('resolved_at')));
    expect(body, isNot(contains('created_from_check')));
    expect(body['due_at'], '2026-08-25T00:00:00.000Z');
  });
}
