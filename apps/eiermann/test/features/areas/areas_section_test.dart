import 'dart:async';

import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/areas/areas_providers.dart';
import 'package:eiermann/features/areas/areas_section.dart';
import 'package:eiermann/features/areas/pin_canvas.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:mocktail/mocktail.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

import '../../support/harness.dart';

class _MockAreas extends Mock implements AreasRepository {}

class _MockNestStates extends Mock implements NestStateRepository {}

class _MockNests extends Mock implements NestsRepository {}

class _MockPicker extends Mock implements ImagePicker {}

/// Alternates real-async progress with frame pumps until [done].
///
/// The crop step hands its pixel work to a background isolate, which a widget
/// test's fake clock does not drive — only `runAsync` does — while the route
/// transition around it needs ordinary pumps, and `pump` may not be called from
/// inside `runAsync`. Interleaving is what lets both finish. (Learned in
/// federfall; the same flow, the same trap.)
Future<void> settleAsync(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 60 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
}

/// Bounded pumps: an image that never resolves in a test keeps a spinner
/// running, and `pumpAndSettle` would wait for it forever.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late AppLocalizations de;
  late MaterialLocalizations materialDe;
  late _MockAreas repo;
  late _MockNestStates nestStates;
  late _MockNests nests;

  setUpAll(() async {
    de = await germanStrings();
    materialDe = await GlobalMaterialLocalizations.delegate.load(
      const Locale('de'),
    );
    registerFallbackValue(<String, dynamic>{});
    registerFallbackValue(<http.MultipartFile>[]);
    registerFallbackValue(ImageSource.gallery);
  });

  setUp(() {
    repo = _MockAreas();
    nestStates = _MockNestStates();
    nests = _MockNests();
    when(() => nestStates.forSpot(any())).thenAnswer((_) async => []);
    when(() => nests.forArea(any())).thenAnswer((_) async => []);
    when(
      () => repo.fileUrl(
        any(),
        any(),
        thumb: any(named: 'thumb'),
        token: any(named: 'token'),
      ),
    ).thenAnswer(
      (i) => Uri.parse(
        'http://pb.test/api/files/areas/${i.positionalArguments[0]}'
        '/${i.positionalArguments[1]}'
        '${i.namedArguments[const Symbol('thumb')] == null ? '' : '?thumb='
                  '${i.namedArguments[const Symbol('thumb')]}'}',
      ),
    );
  });

  /// A real, decodable JPEG — the crop screen decodes what it is handed, so the
  /// usual fake bytes would never get past its loading placeholder.
  final photoBytes = img.encodeJpg(img.Image(width: 40, height: 40));

  /// A picker that returns [photoBytes] under a NON-JPEG name, so the
  /// re-encode's effect on the upload filename is visible.
  _MockPicker pickerReturningPhoto() {
    final picker = _MockPicker();
    when(
      () => picker.pickImage(source: any(named: 'source')),
    ).thenAnswer((_) async => XFile.fromData(photoBytes, name: 'shot.png'));
    return picker;
  }

  Future<void> pump(
    WidgetTester tester,
    List<Area> areas, {
    ImagePicker? picker,
    List<NestState> nestRows = const [],
  }) async {
    when(() => repo.forSpot(any())).thenAnswer((_) async => areas);
    when(() => nestStates.forSpot(any())).thenAnswer((_) async => nestRows);
    await tester.pumpApp(
      const Scaffold(
        body: SingleChildScrollView(child: AreasSection(spotId: 's1')),
      ),
      overrides: [
        areasRepositoryProvider.overrideWith((ref) async => repo),
        nestStateRepositoryProvider.overrideWith((ref) async => nestStates),
        nestsRepositoryProvider.overrideWith((ref) async => nests),
        if (picker != null) imagePickerProvider.overrideWithValue(picker),
        currentUserProvider.overrideWith(
          (ref) async => const AppUser(
            id: 'u1',
            email: 'feld@eiermann.test',
            role: UserRole.member,
            org: 'org00000default',
          ),
        ),
      ],
    );
    await tester.pumpAndSettle();
  }

  const withPhoto = Area(
    id: 'a1',
    name: 'Dachboden Nord',
    spot: 's1',
    photo: 'dachboden.jpg',
  );

  const withoutPhoto = Area(id: 'a2', name: 'Lichtschacht', spot: 's1');

  testWidgets('an empty list says what a Bereich is FOR', (tester) async {
    // "Bereich" alone tells a new volunteer nothing. The empty state has to
    // name the photo and the nests, or the button beside it is a mystery.
    await pump(tester, []);

    expect(find.text(de.areasEmpty), findsOneWidget);
    expect(find.text(de.areasAddAction), findsOneWidget);
  });

  testWidgets('a Bereich without a photo says what that COSTS', (tester) async {
    // Not "no photo" alone: the server refuses a pin on a Bereich without one,
    // so this is a blocked next step rather than a cosmetic gap.
    await pump(tester, [withoutPhoto]);

    expect(find.text(de.areaPhotoMissing), findsOneWidget);
    expect(find.text(de.areaPhotoMissingHint), findsOneWidget);
  });

  testWidgets('a photo is drawn from the 1200px generation, not the original', (
    tester,
  ) async {
    // A phone photo of several megabytes down a stairwell connection, to be
    // drawn 300px wide, is how this screen would come to feel broken.
    await pump(tester, [withPhoto]);
    await settle(tester);

    final image = tester.widget<CachedFileImage>(
      find.byType(CachedFileImage),
    );
    expect(image.url.queryParameters['thumb'], '1200x1200');
    // Contained, not cropped to fill: the pins go on this image later, and a
    // card that hid a third of it would hide nests.
    expect(image.fit, BoxFit.contain);
  });

  testWidgets('the raised review flag is STATED, not swallowed', (
    tester,
  ) async {
    // An area whose pins nobody has checked against the new photo is the one
    // state where the picture actively misleads.
    await pump(tester, [withPhoto.copyWith(pinsNeedReview: true)]);
    await settle(tester);

    expect(find.text(de.areaPinsNeedReview), findsOneWidget);
  });

  testWidgets('a quiet Bereich says nothing about a review', (tester) async {
    await pump(tester, [withPhoto]);
    await settle(tester);

    expect(find.text(de.areaPinsNeedReview), findsNothing);
  });

  testWidgets('how old the photo is, in LOCAL time', (tester) async {
    // PocketBase stores UTC and neither DateFormat nor MaterialLocalizations
    // converts: at 23:30 UTC in CET this would name the previous day, which is
    // invisible on a UTC CI machine.
    final taken = DateTime.utc(2026, 8, 19, 22, 30);
    await pump(tester, [withPhoto.copyWith(photoTakenAt: taken)]);
    await settle(tester);

    expect(
      find.text(de.areaPhotoTakenOn(formatLocalDate(materialDe, taken))),
      findsOneWidget,
    );
  });

  testWidgets('each Bereich lists ITS nests, and only those', (tester) async {
    // One read for the whole dossier, sliced per card. A card that fetched its
    // own would be a request per Bereich — which is what the view exists to
    // prevent, and what would make this screen slow on exactly the buildings
    // that have several.
    await pump(
      tester,
      [withPhoto, withoutPhoto],
      nestRows: [
        NestState(
          id: 'n1',
          label: 'N1',
          area: withPhoto.id,
          urgency: 3,
          spot: 's1',
          dummyCount: 2,
        ),
        NestState(
          id: 'n2',
          label: 'L1',
          area: withoutPhoto.id,
          urgency: 3,
          spot: 's1',
        ),
      ],
    );
    await settle(tester);

    final firstCard = find.ancestor(
      of: find.text(withPhoto.name),
      matching: find.byType(AreaCard),
    );
    expect(
      find.descendant(of: firstCard, matching: find.text('N1')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: firstCard, matching: find.text('L1')),
      findsNothing,
    );
    verify(() => nestStates.forSpot('s1')).called(1);
  });

  testWidgets('the pins are drawn ON the preview photo', (tester) async {
    // The concept's first second: the picture with the nests marked on it, so
    // you orient yourself physically before reading a word.
    await pump(
      tester,
      [withPhoto],
      nestRows: [
        NestState(
          id: 'n1',
          label: 'N1',
          area: withPhoto.id,
          urgency: 3,
          spot: 's1',
          pinX: 0.4,
          pinY: 0.6,
        ),
      ],
    );
    await settle(tester);

    expect(find.byType(PinCanvas), findsOneWidget);
    // Twice: once as a pin on the photo, once as a line under it.
    expect(find.text('N1'), findsNWidgets(2));
  });

  testWidgets('an UNPINNED nest gets a line but no marker', (tester) async {
    // 0/0 is what an unpinned nest arrives as. A marker there would claim the
    // top-left corner of the attic.
    await pump(
      tester,
      [withPhoto],
      nestRows: [
        NestState(
          id: 'n1',
          label: 'N1',
          area: withPhoto.id,
          urgency: 3,
          spot: 's1',
          pinX: 0,
          pinY: 0,
        ),
      ],
    );
    await settle(tester);

    expect(find.text('N1'), findsOneWidget);
  });

  testWidgets('the pins do not swallow the tap into the editor', (
    tester,
  ) async {
    // The pins are read-only here; the whole picture is the way in. A pin that
    // took the tap would leave the reader with no way to move it.
    await pump(
      tester,
      [withPhoto],
      nestRows: [
        NestState(
          id: 'n1',
          label: 'N1',
          area: withPhoto.id,
          urgency: 3,
          spot: 's1',
          pinX: 0.5,
          pinY: 0.5,
        ),
      ],
    );
    await settle(tester);

    final pin = find.descendant(
      of: find.byType(PinCanvas),
      matching: find.text('N1'),
    );
    expect(
      tester
          .widget<IgnorePointer>(
            find.ancestor(of: pin, matching: find.byType(IgnorePointer)).first,
          )
          .ignoring,
      isTrue,
    );
  });

  group('the photo flow', () {
    testWidgets('a picked photo goes through the CROP step before upload', (
      tester,
    ) async {
      await pump(tester, [withoutPhoto], picker: pickerReturningPhoto());

      await tester.tap(find.byTooltip(de.areaPhotoSetAction));
      await tester.pumpAndSettle();
      await tester.tap(find.text(de.areaPhotoGalleryAction));
      await settle(tester);

      expect(find.byType(ImageCropScreen), findsOneWidget);
      verifyNever(() => repo.updateWithFiles(any(), any(), any()));
    });

    testWidgets('backing out of the crop uploads NOTHING', (tester) async {
      // The Bereich keeps the photo it had — including none at all. Cancelling
      // halfway must not leave a half-changed record behind.
      await pump(tester, [withoutPhoto], picker: pickerReturningPhoto());

      await tester.tap(find.byTooltip(de.areaPhotoSetAction));
      await tester.pumpAndSettle();
      await tester.tap(find.text(de.areaPhotoGalleryAction));
      await settle(tester);
      // A fullscreen dialog's leading affordance is Close, not Back.
      await tester.tap(find.byTooltip(materialDe.closeButtonTooltip));
      await settle(tester);

      expect(find.byType(ImageCropScreen), findsNothing);
      verifyNever(() => repo.updateWithFiles(any(), any(), any()));
    });

    testWidgets('confirming the crop uploads a JPEG on the photo field', (
      tester,
    ) async {
      final uploaded =
          Completer<(Map<String, dynamic>, List<http.MultipartFile>)>();
      when(() => repo.updateWithFiles(any(), any(), any())).thenAnswer((
        i,
      ) async {
        uploaded.complete((
          i.positionalArguments[1] as Map<String, dynamic>,
          i.positionalArguments[2] as List<http.MultipartFile>,
        ));
        return withoutPhoto;
      });
      await pump(tester, [withoutPhoto], picker: pickerReturningPhoto());

      await tester.tap(find.byTooltip(de.areaPhotoSetAction));
      await tester.pumpAndSettle();
      await tester.tap(find.text(de.areaPhotoGalleryAction));
      await settle(tester);
      await tester.tap(find.text(de.actionSave));
      await settleAsync(tester, () => uploaded.isCompleted);

      final (body, files) = await uploaded.future;
      expect(files.single.field, 'photo');
      // The crop re-encodes as JPEG, so the picked `.png` name must not
      // survive onto the stored file.
      expect(files.single.filename, endsWith('.jpg'));
      // When the photo was taken travels with it; the fields the replacement
      // hook owns do not.
      expect(body.containsKey('photo_taken_at'), isTrue);
      expect(body.containsKey('previous_photo'), isFalse);
      expect(body.containsKey('pins_need_review'), isFalse);
    });

    testWidgets('a Bereich that HAS a photo offers to replace it', (
      tester,
    ) async {
      // Replace, not remove: a Bereich exists to carry a photo, and dropping it
      // would strand the pins that sit on it.
      await pump(tester, [withPhoto]);
      await settle(tester);

      expect(find.byTooltip(de.areaPhotoReplaceAction), findsOneWidget);
      expect(find.byTooltip(de.areaPhotoSetAction), findsNothing);
    });
  });
}
