import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

class _MockPb extends Mock implements PocketBase {}

class _MockService extends Mock implements RecordService {}

void main() {
  late _MockPb pb;
  late _MockService spots;
  late _MockService contacts;

  setUp(() {
    pb = _MockPb();
    spots = _MockService();
    contacts = _MockService();
    when(() => pb.collection('spots')).thenReturn(spots);
    when(() => pb.collection('spot_contacts')).thenReturn(contacts);
    when(
      () => pb.filter(any(), any()),
    ).thenAnswer((i) => i.positionalArguments.first as String);
  });

  group('SpotsRepository', () {
    test('getOne maps the record', () async {
      when(
        () => spots.getOne('s1', expand: any(named: 'expand')),
      ).thenAnswer((_) async => RecordModel({'id': 's1', 'name': 'Kirchturm'}));

      final spot = await SpotsRepository(pb).getOne('s1');

      expect(spot.name, 'Kirchturm');
    });

    test('create sends the body and maps the result', () async {
      when(() => spots.create(body: any(named: 'body'))).thenAnswer(
        (_) async => RecordModel({'id': 's2', 'name': 'Alter Speicher'}),
      );

      final spot = await SpotsRepository(pb).create(
        SpotsRepository.body(
          name: 'Alter Speicher',
          phase: SpotPhase.prospect,
          org: 'org1',
        ),
      );

      expect(spot.id, 's2');
      final body = verify(
        () => spots.create(body: captureAny(named: 'body')),
      ).captured.single as Map<String, dynamic>;
      expect(body['name'], 'Alter Speicher');
      expect(body['phase'], 'prospect');
      expect(body['org'], 'org1');
    });
  });

  group('SpotsRepository.body', () {
    test('never sends next_due_at — the rhythm owns it', () {
      // The collection's update rule refuses it, because a client that can set
      // it can make a Spot look visited without anybody going there.
      final body = SpotsRepository.body(
        name: 'Bahnhofstraße 12',
        phase: SpotPhase.active,
      );

      expect(body.containsKey('next_due_at'), isFalse);
    });

    test('omits org on the edit path, so the update rule passes', () {
      // An update rule resolves field references against the STORED record: a
      // body carrying org would be authorised against the old one and land in
      // the new one, which is the one write that could cross tenancy.
      final body = SpotsRepository.body(
        name: 'Bahnhofstraße 12',
        phase: SpotPhase.active,
      );

      expect(body.containsKey('org'), isFalse);
    });

    test('writes an emptied text field as empty, so it really clears', () {
      // PocketBase reads an absent key as "leave it as it was", so omitting a
      // cleared field would silently keep the old value.
      final body = SpotsRepository.body(
        name: 'Bahnhofstraße 12',
        phase: SpotPhase.active,
      );

      expect(body['street'], '');
      expect(body['access_note'], '');
      expect(body['note'], '');
    });

    test('leaves the prospect stage alone when the form does not offer it', () {
      // It stays set after the Spot goes active — the Erkundung history is part
      // of the dossier, and a form that clears it is how the same conversation
      // gets had twice.
      final body = SpotsRepository.body(
        name: 'Bahnhofstraße 12',
        phase: SpotPhase.active,
      );

      expect(body.containsKey('prospect_stage'), isFalse);
    });

    test('writes the wire string, not the Dart identifier', () {
      final body = SpotsRepository.body(
        name: 'Bahnhofstraße 12',
        phase: SpotPhase.prospect,
        prospectStage: ProspectStage.tenantSpoken,
      );

      expect(body['prospect_stage'], 'tenant_spoken');
    });
  });

  group('SpotContactsRepository', () {
    test('forSpot filters by the parent and puts primaries first', () async {
      when(
        () => contacts.getList(
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
            RecordModel({'id': 'c1', 'name': 'Herr Kröger', 'is_primary': true}),
            RecordModel({'id': 'c2', 'name': 'Immobilien Nord'}),
          ],
        ),
      );

      final rows = await SpotContactsRepository(pb).forSpot('s1');

      expect(rows.map((c) => c.name), ['Herr Kröger', 'Immobilien Nord']);
      verify(
        () => contacts.getList(
          page: any(named: 'page'),
          perPage: any(named: 'perPage'),
          skipTotal: any(named: 'skipTotal'),
          filter: 'spot = {:spot}',
          sort: '-is_primary,name',
          expand: any(named: 'expand'),
          fields: any(named: 'fields'),
        ),
      ).called(1);
    });

    test('the body omits spot on the edit path — the parent is frozen', () {
      // An update rule resolves `spot` against the STORED record, so a
      // re-parenting write would be authorised against the old Spot and land
      // on the new one.
      final body = SpotContactsRepository.body(
        name: 'Herr Kröger',
        role: ContactRole.caretaker,
      );

      expect(body.containsKey('spot'), isFalse);
      expect(body['role'], 'caretaker');
      expect(body['is_primary'], isFalse);
    });
  });
}
