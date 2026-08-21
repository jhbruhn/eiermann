import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

class _MockPb extends Mock implements PocketBase {}

class _MockService extends Mock implements RecordService {}

void main() {
  late _MockPb pb;
  late _MockService nests;
  late NestsRepository repo;

  setUp(() {
    pb = _MockPb();
    nests = _MockService();
    when(() => pb.collection('nests')).thenReturn(nests);
    when(
      () => pb.filter(any(), any()),
    ).thenAnswer((i) => i.positionalArguments.first as String);
    repo = NestsRepository(pb);
  });

  RecordModel record(String id, {String label = 'N3'}) =>
      RecordModel({'id': id, 'label': label, 'area': 'a1'});

  void stubUpdate() {
    when(
      () => nests.update(
        any(),
        body: any(named: 'body'),
        files: any(named: 'files'),
      ),
    ).thenAnswer((_) async => record('n1'));
  }

  Map<String, dynamic> capturedUpdate() =>
      verify(
            () => nests.update(
              'n1',
              body: captureAny(named: 'body'),
              files: any(named: 'files'),
            ),
          ).captured.single
          as Map<String, dynamic>;

  group('forArea', () {
    test('asks for one Bereich, by label', () async {
      // By label because that is the caption on the pin and what a volunteer
      // says out loud ("N3 ist leer").
      when(
        () => nests.getList(
          page: any(named: 'page'),
          perPage: any(named: 'perPage'),
          skipTotal: any(named: 'skipTotal'),
          filter: any(named: 'filter'),
          sort: any(named: 'sort'),
          expand: any(named: 'expand'),
          fields: any(named: 'fields'),
        ),
      ).thenAnswer((_) async => ResultList(items: [record('n1')]));

      await repo.forArea('a1');

      final call = verify(
        () => nests.getList(
          page: any(named: 'page'),
          perPage: any(named: 'perPage'),
          skipTotal: any(named: 'skipTotal'),
          filter: captureAny(named: 'filter'),
          sort: captureAny(named: 'sort'),
          expand: any(named: 'expand'),
          fields: any(named: 'fields'),
        ),
      ).captured;
      expect(call[0], 'area = {:area}');
      expect(call[1], 'label');
    });
  });

  group('movePin', () {
    test('sends the two coordinates and NOTHING else', () async {
      // A drag changes two numbers. Sending the whole record back would let a
      // label or a species read before somebody else edited it overwrite the
      // current one.
      stubUpdate();

      await repo.movePin('n1', x: 0.42, y: 0.61);

      expect(capturedUpdate(), {'pin_x': 0.42, 'pin_y': 0.61});
    });

    test('a corner drag is nudged off the ambiguous 0/0', () async {
      // The server clamps into 0…1, so dragging into the top-left corner lands
      // on exactly the value an UNPINNED nest reads as. Writing it would make
      // the pin vanish on the next read.
      stubUpdate();

      await repo.movePin('n1', x: -0.2, y: 0);

      expect(capturedUpdate(), {'pin_x': kPinMin, 'pin_y': kPinMin});
    });
  });

  group('body', () {
    Map<String, dynamic> body({
      double? pinX,
      double? pinY,
      String? area,
      String? org,
    }) => NestsRepository.body(
      label: 'N3',
      species: NestSpecies.unknown,
      status: NestStatus.active,
      positionHint: 'Balken links',
      pinX: pinX,
      pinY: pinY,
      area: area,
      org: org,
    );

    test('a create carries the Bereich and the org', () {
      final created = body(area: 'a1', org: 'org1');

      expect(created['label'], 'N3');
      expect(created['area'], 'a1');
      expect(created['org'], 'org1');
      expect(created['species'], 'unknown');
      expect(created['status'], 'active');
      expect(created['position_hint'], 'Balken links');
    });

    test('never sends `spot` — a hook derives it from the Bereich', () {
      // Denormalised for one-table reads. A client that sent it could make a
      // nest claim a building its Bereich does not belong to; the hook takes it
      // from the area after checking that area against the caller's org.
      expect(body(area: 'a1', org: 'org1').containsKey('spot'), isFalse);
    });

    test("never sends the rhythm — that is the ladder's own state", () {
      // A client that can set these can make a nest look checked without
      // anybody going there. The update rule refuses them outright.
      final created = body(area: 'a1');

      expect(created.containsKey('interval_days'), isFalse);
      expect(created.containsKey('empty_streak'), isFalse);
      expect(created.containsKey('next_due_at'), isFalse);
    });

    test('an update carries neither Bereich nor org', () {
      // Re-parenting a nest would carry its whole check history to another
      // building, so the update rule pins both.
      final updated = body();

      expect(updated.containsKey('area'), isFalse);
      expect(updated.containsKey('org'), isFalse);
    });

    test('a pin travels as a PAIR or not at all', () {
      // Half a pin is not a position: an x with no y would be drawn along the
      // top edge of the photo.
      expect(body(pinX: 0.4).containsKey('pin_x'), isFalse);
      expect(body(pinY: 0.4).containsKey('pin_y'), isFalse);

      final pinned = body(pinX: 0.4, pinY: 0.6);
      expect(pinned['pin_x'], 0.4);
      expect(pinned['pin_y'], 0.6);
    });

    test('a pin in the body is normalised too', () {
      expect(body(pinX: 0, pinY: 0)['pin_x'], kPinMin);
      expect(body(pinX: 1.7, pinY: 2)['pin_y'], 1.0);
    });
  });

  group('delete', () {
    test('is refused in the CLIENT, with the reason', () async {
      // `deleteRule: null` — not even the coordination has this route. A nest
      // that disappeared is a finding: `status = gone` records it instead of
      // erasing every check ever made on it. Failing here names that; letting
      // the call through would return a bare 403 at the worst moment.
      expect(() => repo.delete('n1'), throwsA(isA<UnsupportedError>()));
      verifyNever(() => nests.delete(any()));
    });
  });
}
