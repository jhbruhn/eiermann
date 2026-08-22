import 'dart:typed_data';

import 'package:eiermann_data/eiermann_data.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:test/test.dart';

class _MockPb extends Mock implements PocketBase {}

class _MockAuthStore extends Mock implements AuthStore {}

class _MockHttp extends Mock implements http.Client {}

void main() {
  late _MockPb pb;
  late _MockAuthStore auth;
  late _MockHttp client;
  late ReportsRepository repo;

  setUpAll(() {
    registerFallbackValue(Uri.parse('http://localhost'));
  });

  setUp(() {
    pb = _MockPb();
    auth = _MockAuthStore();
    client = _MockHttp();
    when(() => pb.authStore).thenReturn(auth);
    when(() => auth.isValid).thenReturn(true);
    when(() => auth.token).thenReturn('token-abc');
    when(() => pb.buildURL(any(), any())).thenAnswer((i) {
      final path = i.positionalArguments.first as String;
      final query = i.positionalArguments[1] as Map<String, dynamic>;
      return Uri.parse('http://pb.test$path').replace(
        queryParameters: {
          for (final e in query.entries) e.key: '${e.value}',
        },
      );
    });
    repo = ReportsRepository(pb, httpClient: client);
  });

  void answerWith(int status, List<int> bytes) {
    when(
      () => client.get(any(), headers: any(named: 'headers')),
    ).thenAnswer(
      (_) async => http.Response.bytes(bytes, status),
    );
  }

  Uri sentUri() {
    final call = verify(
      () => client.get(captureAny(), headers: any(named: 'headers')),
    );
    return call.captured.single as Uri;
  }

  test('each format asks the ONE route for its own rendering', () async {
    // One route and three `?format=` values, because they are three renderings
    // of the same rows — not three features.
    for (final format in ReportFormat.values) {
      client = _MockHttp();
      repo = ReportsRepository(pb, httpClient: client);
      answerWith(200, [1, 2, 3]);
      await repo.fetch(format: format, year: 2026);
      final uri = sentUri();
      expect(uri.path, '/api/eiermann/reports/period');
      expect(uri.queryParameters['format'], format.wire);
    }
  });

  test('the wire values are the ones the route branches on', () {
    // A Dart rename must not change what is asked for.
    expect(ReportFormat.authority.wire, 'pdf');
    expect(ReportFormat.summary.wire, 'summary');
    expect(ReportFormat.csv.wire, 'csv');
    expect(ReportFormat.summary.extension, 'pdf');
    expect(ReportFormat.csv.mimeType, 'text/csv');
  });

  test('the bytes come back untouched', () async {
    // Through an HTTP client rather than the PocketBase SDK, which decodes
    // every response as JSON and would corrupt a PDF.
    answerWith(200, [0x25, 0x50, 0x44, 0x46, 0x2d]);
    final bytes = await repo.fetch(format: ReportFormat.authority);
    expect(bytes, isA<Uint8List>());
    expect(bytes.sublist(0, 5), [0x25, 0x50, 0x44, 0x46, 0x2d]);
  });

  test('the period, the language and the offset all travel', () async {
    answerWith(200, [1]);
    await repo.fetch(
      format: ReportFormat.csv,
      year: 2026,
      month: 3,
      lang: 'en',
      tzOffsetMinutes: 60,
    );
    final query = sentUri().queryParameters;
    expect(query['year'], '2026');
    expect(query['month'], '3');
    expect(query['lang'], 'en');
    // The server has no timezone database: this offset is what makes the
    // exported file and the figures on screen agree about what a year is.
    expect(query['tzOffsetMinutes'], '60');
  });

  test('a month is never sent without its year', () async {
    answerWith(200, [1]);
    await repo.fetch(format: ReportFormat.csv, month: 3);
    expect(sentUri().queryParameters.containsKey('month'), isFalse);
  });

  test('the token goes with the request', () async {
    // The route is behind `requireAuth` and the org scope comes off the caller,
    // so an unauthenticated fetch is not a narrower report — it is a 401.
    answerWith(200, [1]);
    await repo.fetch(format: ReportFormat.authority);
    final headers =
        verify(
              () => client.get(any(), headers: captureAny(named: 'headers')),
            ).captured.single
            as Map<String, String>;
    expect(headers['Authorization'], 'token-abc');
  });

  test('a refusal is a RepositoryException, not error text in a file', () {
    // Otherwise a 403's JSON body would reach the share sheet as a "report".
    answerWith(403, [1, 2]);
    return expectLater(
      repo.fetch(format: ReportFormat.authority),
      throwsA(isA<RepositoryException>()),
    );
  });

  test('a stalled render times out rather than spinning forever', () async {
    repo = ReportsRepository(
      pb,
      httpClient: client,
      networkTimeout: const Duration(milliseconds: 20),
    );
    when(() => client.get(any(), headers: any(named: 'headers'))).thenAnswer(
      (_) => Future.delayed(
        const Duration(seconds: 5),
        () => http.Response.bytes([1], 200),
      ),
    );
    await expectLater(
      repo.fetch(format: ReportFormat.authority),
      throwsA(
        isA<RepositoryException>().having(
          (e) => e.kind,
          'kind',
          RepositoryErrorKind.network,
        ),
      ),
    );
  });
}
