import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'sweep_sources.dart';

void main() {
  final root = repoRoot.path;

  /// Every hand-written test file in the app package, guards excluded — a guard
  /// reads source rather than pumping widgets, so the rules below do not apply
  /// to it.
  Iterable<File> appTests() => Directory('$root/apps/eiermann/test')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('_test.dart'))
      .where((f) => !f.path.contains('/test/guards/'));

  group('the widget-test harness', () {
    test('no test sets the surface by hand', () {
      // The three lines are `physicalSize`, `devicePixelRatio` and the
      // teardown, and it is the teardown that gets written wrong.
      // `resetPhysicalSize` restores the size and LEAVES the pixel ratio at 1,
      // so the next test in the same file runs at a ratio it never set and its
      // 800x600 is physical rather than logical. Fifteen call sites had it both
      // ways before `useSurface` existed — which is a coin flip on whether a
      // below-the-fold assertion means anything.
      final offenders = <String>[];
      for (final file in appTests()) {
        final source = file.readAsStringSync();
        for (final needle in [
          'view.physicalSize',
          'view.devicePixelRatio',
          'resetPhysicalSize',
        ]) {
          if (source.contains(needle)) {
            offenders.add('${relative(file)}: $needle');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'use `tester.useSurface(const Size(w, h))` from support/harness.dart',
      );
    });

    test('...and the tests that need a tall surface use the helper', () {
      // The canary. If `useSurface` stopped being called the guard above would
      // pass over a suite that had gone back to 800x600 everywhere, and the
      // below-the-fold failures would read as missing controls again.
      final users = appTests()
          .where((f) => f.readAsStringSync().contains('useSurface('))
          .length;
      expect(
        users,
        greaterThan(10),
        reason: 'a sweep over nothing passes over anything',
      );
    });

    test('no test reaches the real device', () {
      // The image picker and the location service are injected through
      // providers precisely so a test never touches the platform: a real
      // `ImagePicker()` in a widget test hangs on a channel nobody answers, and
      // a real geolocator asks a permission dialog that does not exist. Both
      // seams already have a provider — the failure mode is a NEW test that
      // constructs one directly because it did not know.
      final offenders = <String>[];
      for (final file in appTests()) {
        for (final needle in ['ImagePicker()', 'Geolocator.']) {
          if (file.readAsStringSync().contains(needle)) {
            offenders.add('${relative(file)}: $needle');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'override imagePickerProvider / the location provider with a mock',
      );
    });

    test('the binding hook is the only place zugvogel is bound', () {
      // `flutter_test_config.dart` is the only hook Flutter runs around EVERY
      // test in a package, which is what makes it the right place — and what
      // makes a second `bindZugvogel()` in a single test file a trap: that test
      // passes alone and the next one to need a different config finds it
      // already bound.
      final config = File(
        '$root/apps/eiermann/test/flutter_test_config.dart',
      ).readAsStringSync();
      expect(config, contains('bindZugvogel()'));
      final offenders = appTests()
          .where((f) => f.readAsStringSync().contains('bindZugvogel('))
          .map(relative)
          .toList();
      expect(
        offenders,
        isEmpty,
        reason: 'flutter_test_config.dart already binds it for every test',
      );
    });
  });
}
