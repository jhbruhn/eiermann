import 'package:eiermann_data/eiermann_data.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

class _MockPb extends Mock implements PocketBase {}

void main() {
  late _MockPb pb;

  setUp(() {
    pb = _MockPb();
  });

  /// Stubs the proxy's answer for one route.
  void answers(String path, Map<String, dynamic> body) {
    when(
      () => pb.send<Map<String, dynamic>>(
        path,
        query: any(named: 'query'),
      ),
    ).thenAnswer((_) async => body);
  }

  Map<String, dynamic> sentQuery(String path) =>
      verify(
            () => pb.send<Map<String, dynamic>>(
              path,
              query: captureAny(named: 'query'),
            ),
          ).captured.single
          as Map<String, dynamic>;

  group('forward', () {
    test("asks the app's own proxy, never a geocoder", () async {
      // A browser cannot call Nominatim at all (no CORS headers), the upstream
      // needs a real contact in its User-Agent, and the rate limit has to sit
      // somewhere a client cannot bypass. All three are the server's job.
      answers('/api/eiermann/geocode', {'results': <Object>[]});

      await PbGeocodingRepository(pb).forward('Bahnhofstr. 12, Oldenburg');

      expect(sentQuery('/api/eiermann/geocode'), {
        'q': 'Bahnhofstr. 12, Oldenburg',
      });
    });

    test('maps the candidates in the order they came', () async {
      // Best first is the geocoder's judgement, relayed by the proxy.
      // Re-sorting client-side would put a plausible street in the wrong town
      // at the top.
      answers('/api/eiermann/geocode', {
        'results': [
          {
            'lat': 53.1435,
            'lon': 8.2146,
            'displayName': 'Bahnhofstraße 12, 26122 Oldenburg',
            'city': 'Oldenburg',
            'region': 'Niedersachsen',
          },
          {'lat': 52.52, 'lon': 13.4, 'displayName': 'Bahnhofstraße 12'},
        ],
      });

      final results = await PbGeocodingRepository(
        pb,
      ).forward('Bahnhofstraße 12');

      expect(results, hasLength(2));
      expect(results.first.city, 'Oldenburg');
      expect(results.first.point.lat, 53.1435);
      expect(results.first.point.lon, 8.2146);
      // Absent strings are empty, not null: a candidate with no town is still
      // a usable pin.
      expect(results.last.city, '');
    });

    test('SKIPS a candidate with no numeric coordinates', () async {
      // The one that matters. A third-party geocoder sits behind this proxy,
      // and an entry defaulted to (0, 0) is a plausible-looking marker in the
      // Gulf
      // of Guinea that somebody could save onto a building in Oldenburg — after
      // which GeoPoint.fromPb reads it back as "no pin" and the wrong door is
      // invisible in the data.
      answers('/api/eiermann/geocode', {
        'results': [
          {'lat': 'nördlich', 'lon': 8.2146, 'displayName': 'Kaputt'},
          {'lon': 8.2146, 'displayName': 'Kein lat'},
          <String, dynamic>{},
          'nicht einmal eine Map',
          {'lat': 53.1435, 'lon': 8.2146, 'displayName': 'Heil'},
        ],
      });

      final results = await PbGeocodingRepository(pb).forward('Kaputt');

      expect(results, hasLength(1));
      expect(results.single.displayName, 'Heil');
    });

    test('a response with no results at all is an empty list', () async {
      // Not an error: "nothing found for that address" is an answer, and the
      // screen offers to place the pin by hand.
      answers('/api/eiermann/geocode', <String, dynamic>{});

      expect(await PbGeocodingRepository(pb).forward('Nirgendwo'), isEmpty);
    });
  });

  group('reverse', () {
    test('sends the coordinates as plain numbers', () async {
      answers('/api/eiermann/geocode/reverse', {'result': null});

      await PbGeocodingRepository(pb).reverse(53.1435, 8.2146);

      expect(sentQuery('/api/eiermann/geocode/reverse'), {
        'lat': '53.1435',
        'lon': '8.2146',
      });
    });

    test('an unresolved pin is null, not an error', () async {
      // A pin in the North Sea has no address. The proxy caches that as a
      // negative result, and the caller treats it the same as "no result".
      answers('/api/eiermann/geocode/reverse', {'result': null});

      expect(await PbGeocodingRepository(pb).reverse(54.5, 5.1), isNull);
    });

    test('a malformed result reads as unresolved too', () async {
      answers('/api/eiermann/geocode/reverse', {
        'result': {'lat': null, 'lon': null},
      });

      expect(await PbGeocodingRepository(pb).reverse(53.1, 8.2), isNull);
    });

    test('a resolved pin comes back with its address', () async {
      answers('/api/eiermann/geocode/reverse', {
        'result': {
          'lat': 53.1435,
          'lon': 8.2146,
          'displayName': 'Bahnhofstraße 12, 26122 Oldenburg',
          'city': 'Oldenburg',
          'region': 'Niedersachsen',
        },
      });

      final result = await PbGeocodingRepository(pb).reverse(53.1435, 8.2146);

      expect(result?.displayName, 'Bahnhofstraße 12, 26122 Oldenburg');
      expect(result?.city, 'Oldenburg');
    });
  });

  group('failures', () {
    test('an unreachable SERVER is a network error', () async {
      when(
        () => pb.send<Map<String, dynamic>>(any(), query: any(named: 'query')),
      ).thenThrow(ClientException());

      await expectLater(
        PbGeocodingRepository(pb).forward('Oldenburg'),
        throwsA(
          isA<RepositoryException>().having(
            (e) => e.kind,
            'kind',
            RepositoryErrorKind.network,
          ),
        ),
      );
    });

    test("an unreachable GEOCODER is the proxy's 502, and is not", () async {
      // Worth telling apart in the UI: the server is fine, the address entry
      // still works, and only the coordinate lookup is out — so the sheet must
      // not tell the user they are offline.
      when(
        () => pb.send<Map<String, dynamic>>(any(), query: any(named: 'query')),
      ).thenThrow(ClientException(statusCode: 502));

      await expectLater(
        PbGeocodingRepository(pb).forward('Oldenburg'),
        throwsA(
          isA<RepositoryException>().having(
            (e) => e.kind,
            'kind',
            isNot(RepositoryErrorKind.network),
          ),
        ),
      );
    });

    test('a timeout is a network error, never unknownOutcome', () async {
      // Both routes are GETs. There is no write that might have
      // half-committed, so "not reached, try again" is the truthful message
      // here — the one place it is safe to say.
      when(
        () => pb.send<Map<String, dynamic>>(any(), query: any(named: 'query')),
      ).thenAnswer(
        (_) => Future.delayed(
          const Duration(milliseconds: 80),
          () => <String, dynamic>{},
        ),
      );

      await expectLater(
        PbGeocodingRepository(
          pb,
          networkTimeout: const Duration(milliseconds: 10),
        ).forward('Oldenburg'),
        throwsA(
          isA<RepositoryException>().having(
            (e) => e.kind,
            'kind',
            RepositoryErrorKind.network,
          ),
        ),
      );
    });

    test(
      'an unexpected shape still surfaces as a RepositoryException',
      () async {
        // The type the UI error states depend on. A raw TypeError from a mapper
        // would reach the screen as "something went wrong" with no copy at all.
        when(
          () =>
              pb.send<Map<String, dynamic>>(any(), query: any(named: 'query')),
        ).thenAnswer((_) async => {'results': 'not a list'});

        await expectLater(
          PbGeocodingRepository(pb).forward('Oldenburg'),
          throwsA(isA<RepositoryException>()),
        );
      },
    );
  });
}
