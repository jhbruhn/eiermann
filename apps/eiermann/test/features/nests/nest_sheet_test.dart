import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/areas/areas_providers.dart';
import 'package:eiermann/features/nests/nest_sheet.dart';
import 'package:eiermann/features/nests/nests_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:mocktail/mocktail.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

import '../../support/harness.dart';

class _MockNests extends Mock implements NestsRepository {}

class _MockPicker extends Mock implements ImagePicker {}

const _nest = Nest(
  id: 'n1',
  label: 'N3',
  area: 'a1',
  species: NestSpecies.feralPigeon,
  status: NestStatus.active,
  pinX: 0.4,
  pinY: 0.6,
);

void main() {
  late AppLocalizations de;
  late _MockNests repo;

  setUpAll(() async {
    de = await germanStrings();
    registerFallbackValue(<String, dynamic>{});
    registerFallbackValue(<http.MultipartFile>[]);
    registerFallbackValue(ImageSource.gallery);
  });

  setUp(() {
    repo = _MockNests();
    when(
      () => repo.createWithFiles(any(), any()),
    ).thenAnswer((_) async => _nest);
    when(
      () => repo.updateWithFiles(any(), any(), any()),
    ).thenAnswer((_) async => _nest);
    when(
      () => repo.fileUrl(
        any(),
        any(),
        thumb: any(named: 'thumb'),
        token: any(named: 'token'),
      ),
    ).thenReturn(Uri.parse('http://pb.test/api/files/nests/n1/nest.jpg'));
    when(() => repo.create(any())).thenAnswer((_) async => _nest);
    when(() => repo.update(any(), any())).thenAnswer((_) async => _nest);
    when(() => repo.forArea(any())).thenAnswer((_) async => []);
  });

  /// A real, decodable JPEG — the crop screen decodes what it is handed.
  final photoBytes = img.encodeJpg(img.Image(width: 40, height: 40));

  _MockPicker pickerReturningPhoto() {
    final picker = _MockPicker();
    when(
      () => picker.pickImage(source: any(named: 'source')),
    ).thenAnswer((_) async => XFile.fromData(photoBytes, name: 'shot.png'));
    return picker;
  }

  Future<void> pump(
    WidgetTester tester, {
    Nest? nest,
    ({double x, double y})? pin,
    String? suggestedLabel,
    UserRole role = UserRole.member,
    ImagePicker? picker,
  }) async {
    // A TALL surface. The sheet is one scroll view, and a `ListView` does not
    // build what is below the fold — so on the default 800x600 the save button
    // drops out of the tree as soon as something is inserted above it, and
    // the test then reads as "the save did nothing" rather than "the button is
    // offscreen". It cost exactly that when the species field grew a
    // suggestion row.
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpApp(
      Scaffold(
        body: NestSheet(
          areaId: 'a1',
          nest: nest,
          pin: pin,
          suggestedLabel: suggestedLabel,
        ),
      ),
      overrides: [
        nestsRepositoryProvider.overrideWith((ref) async => repo),
        if (picker != null) imagePickerProvider.overrideWithValue(picker),
        currentUserProvider.overrideWith(
          (ref) async => AppUser(
            id: 'u1',
            email: 'feld@eiermann.test',
            role: role,
            org: 'org00000default',
          ),
        ),
      ],
    );
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> captureCreate() =>
      verify(() => repo.create(captureAny())).captured.single
          as Map<String, dynamic>;

  Map<String, dynamic> captureUpdate() =>
      verify(() => repo.update('n1', captureAny())).captured.single
          as Map<String, dynamic>;

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.text(de.actionSave));
    await tester.pumpAndSettle();
  }

  group('suggestNestLabel', () {
    test('the first nest of a Bereich is N1', () {
      expect(suggestNestLabel([]), 'N1');
    });

    test('it counts up past what is there', () {
      expect(suggestNestLabel(['N1', 'N2']), 'N3');
    });

    test('it fills a GAP rather than proposing a taken label', () {
      // The label is unique per Bereich, so proposing "N3" when N3 exists would
      // be refused — after the volunteer had already filled the sheet in.
      expect(suggestNestLabel(['N1', 'N3']), 'N2');
    });

    test('a hand-written label does not confuse the count', () {
      expect(suggestNestLabel(['Kamin']), 'N1');
    });
  });

  testWidgets('a tapped position travels into the create as a PAIR', (
    tester,
  ) async {
    // One write for one gesture. Creating the row first and pinning it after
    // would leave an unnamed nest behind whenever somebody backs out.
    await pump(tester, pin: (x: 0.25, y: 0.75), suggestedLabel: 'N4');

    await save(tester);

    final body = captureCreate();
    expect(body['label'], 'N4');
    expect(body['pin_x'], 0.25);
    expect(body['pin_y'], 0.75);
    expect(body['area'], 'a1');
    expect(body['org'], 'org00000default');
  });

  testWidgets('the suggested label is offered, not imposed', (tester) async {
    await pump(tester, pin: (x: 0.5, y: 0.5), suggestedLabel: 'N4');
    await tester.enterText(find.byType(TextFormField).first, 'Kamin');

    await save(tester);

    expect(captureCreate()['label'], 'Kamin');
  });

  testWidgets('an EDIT never re-sends the pin', (tester) async {
    // The drag on the photo owns the pin. Sending the pair the sheet was opened
    // with would undo a move somebody made in between.
    await pump(tester, nest: _nest);
    await tester.enterText(find.byType(TextFormField).first, 'N9');

    await save(tester);

    final body = captureUpdate();
    expect(body['label'], 'N9');
    expect(body.containsKey('pin_x'), isFalse);
    expect(body.containsKey('pin_y'), isFalse);
    expect(body.containsKey('area'), isFalse);
  });

  testWidgets('a new nest is UNBESTIMMT until somebody says otherwise', (
    tester,
  ) async {
    // The app does not identify species. Defaulting to "city pigeon" would be
    // the app making that call — and it is the one call that can be illegal.
    await pump(tester, pin: (x: 0.5, y: 0.5), suggestedLabel: 'N1');

    await save(tester);

    expect(captureCreate()['species'], NestSpecies.unknown.wire);
  });

  testWidgets('marking a nest GESCHÜTZT is open to a member', (tester) async {
    // The volunteer standing in front of a jackdaw must be able to stop the
    // process immediately, without finding a coordinator first.
    await pump(tester, pin: (x: 0.5, y: 0.5), suggestedLabel: 'N1');

    await tester.tap(find.text(de.nestSpeciesProtected));
    await tester.pumpAndSettle();
    await save(tester);

    expect(captureCreate()['species'], NestSpecies.protected.wire);
  });

  testWidgets('a member cannot take a protected nest BACK', (tester) async {
    // The way out re-enables egg removal on that nest. The hook refuses it too
    // — this is the half that keeps a member from tapping an option that would
    // come back 403.
    await pump(
      tester,
      nest: _nest.copyWith(species: NestSpecies.protected),
    );

    expect(find.text(de.nestProtectedLockedHint), findsOneWidget);
    await tester.tap(find.text(de.nestSpeciesFeralPigeon));
    await tester.pumpAndSettle();
    await save(tester);

    // Still protected: the tap did nothing at all.
    expect(captureUpdate()['species'], NestSpecies.protected.wire);
  });

  testWidgets('the coordination CAN take it back', (tester) async {
    await pump(
      tester,
      nest: _nest.copyWith(species: NestSpecies.protected),
      role: UserRole.coordinator,
    );

    expect(find.text(de.nestProtectedLockedHint), findsNothing);
    await tester.tap(find.text(de.nestSpeciesFeralPigeon));
    await tester.pumpAndSettle();
    await save(tester);

    expect(captureUpdate()['species'], NestSpecies.feralPigeon.wire);
  });

  testWidgets('the species NAME is asked for unless it is a city pigeon', (
    tester,
  ) async {
    // Free text, because a curated list goes stale — and it only makes sense
    // where the species is the open question.
    await pump(tester, pin: (x: 0.5, y: 0.5), suggestedLabel: 'N1');
    expect(find.text(de.nestFieldSpeciesLabel), findsOneWidget);

    await tester.tap(find.text(de.nestSpeciesFeralPigeon));
    await tester.pumpAndSettle();

    expect(find.text(de.nestFieldSpeciesLabel), findsNothing);
  });

  testWidgets('a nameless nest is refused before the request', (tester) async {
    // The label is the caption on the pin. A nest without one cannot be pointed
    // at in an attic, and the server requires it anyway.
    await pump(tester, pin: (x: 0.5, y: 0.5));

    await save(tester);

    verifyNever(() => repo.create(any()));
  });

  group("the nest's own photo", () {
    /// Alternates real-async progress with frame pumps until [done]: the crop
    /// step's pixel work runs off the fake clock, and `pump` cannot be called
    /// from inside `runAsync`.
    Future<void> settleAsync(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 60 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        // WITH a duration: a bare `pump()` advances the fake clock by nothing,
        // so a route transition never finishes and the button being tapped is
        // still sliding in from the right — measured at x=924 in an 800px view,
        // which reads as "the tap missed" three steps later.
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    /// Real-async progress for a fixed number of rounds.
    ///
    /// The crop screen DECODES the photo before it can offer a confirm button,
    /// and a decode is real async work: plain pumps leave the button disabled,
    /// a tap on it does nothing at all, and the failure looks like "the crop is
    /// still open" three steps later.
    Future<void> pumpAsync(WidgetTester tester, [int rounds = 20]) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    /// Takes a photo into the sheet: source, then crop, then confirm.
    ///
    /// The crop's confirm button is found INSIDE `ImageCropScreen`. Both it and
    /// the sheet underneath say "Speichern", and an unscoped finder taps
    /// whichever comes first — which is how this test first hung rather than
    /// failed.
    Future<void> stagePhoto(WidgetTester tester) async {
      await tester.tap(find.text(de.nestPhotoSetAction));
      await tester.pumpAndSettle();
      await tester.tap(find.text(de.photoGalleryAction));
      await pumpAsync(tester);
      expect(
        find.byType(ImageCropScreen),
        findsOneWidget,
        reason: 'the crop step comes between picking and saving',
      );
      await tester.tap(
        find.descendant(
          of: find.byType(ImageCropScreen),
          matching: find.text(de.actionSave),
        ),
      );
      // The confirm re-encodes the pixels in a background isolate, which a
      // widget test's fake clock does not drive — only `runAsync` does. Plain
      // pumps leave the crop screen standing there forever.
      await settleAsync(
        tester,
        () => find.byType(ImageCropScreen).evaluate().isEmpty,
      );
    }

    testWidgets('a photo taken while creating travels WITH the create', (
      tester,
    ) async {
      // One request for one nest. Creating the row and then uploading would
      // leave a nest without its picture visible to everybody else in between —
      // and an abandoned sheet would leave the row behind.
      //
      // A flag rather than a Completer to wait on: an awaited future that never
      // completes HANGS the test instead of failing it, which is how this one
      // first burned two minutes and reported nothing.
      var sent = false;
      Map<String, dynamic>? body;
      List<http.MultipartFile>? files;
      when(() => repo.createWithFiles(any(), any())).thenAnswer((i) async {
        sent = true;
        body = i.positionalArguments[0] as Map<String, dynamic>;
        files = i.positionalArguments[1] as List<http.MultipartFile>;
        return _nest;
      });
      await pump(
        tester,
        pin: (x: 0.5, y: 0.5),
        suggestedLabel: 'N4',
        picker: pickerReturningPhoto(),
      );

      await stagePhoto(tester);
      expect(
        find.byType(ImageCropScreen),
        findsNothing,
        reason: 'the crop was confirmed, so it must be off the screen',
      );
      // Nothing has been sent yet: the photo is a field of a form somebody is
      // still filling in.
      expect(sent, isFalse);
      verifyNever(() => repo.create(any()));

      await tester.tap(find.text(de.actionSave));
      await settleAsync(tester, () => sent);

      expect(sent, isTrue, reason: 'the save has to carry the file');
      expect(body!['label'], 'N4');
      expect(files!.single.field, 'photo');
      // Re-encoded by the crop, so the picked `.png` name must not survive.
      expect(files!.single.filename, endsWith('.jpg'));
      verifyNever(() => repo.create(any()));
    });

    testWidgets('a stored photo can be removed, in the same save', (
      tester,
    ) async {
      // Removable, unlike the Bereich photo: that one carries the pins and
      // dropping it strands them. This one carries nothing but itself.
      await pump(tester, nest: _nest.copyWith(photo: 'nest.jpg'));

      await tester.tap(find.text(de.photoRemoveAction));
      await tester.pumpAndSettle();
      await save(tester);

      final body = captureUpdate();
      expect(body.containsKey('photo'), isTrue);
      expect(body['photo'], isNull);
      verifyNever(() => repo.updateWithFiles(any(), any(), any()));
    });

    testWidgets('an untouched photo is not mentioned in the save at all', (
      tester,
    ) async {
      // Sending `photo: null` for "unchanged" would delete it.
      await pump(tester, nest: _nest.copyWith(photo: 'nest.jpg'));
      await tester.enterText(find.byType(TextFormField).first, 'N9');

      await save(tester);

      expect(captureUpdate().containsKey('photo'), isFalse);
    });

    testWidgets('a nest with no photo offers to take one', (tester) async {
      await pump(tester, nest: _nest);

      expect(find.text(de.nestPhotoSetAction), findsOneWidget);
      expect(find.text(de.photoRemoveAction), findsNothing);
    });

    testWidgets('a nest WITH one offers to replace it', (tester) async {
      await pump(tester, nest: _nest.copyWith(photo: 'nest.jpg'));

      expect(find.text(de.nestPhotoReplaceAction), findsOneWidget);
      expect(find.text(de.photoRemoveAction), findsOneWidget);
    });
  });
}
