@Tags(['guard'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'sweep_sources.dart';

/// eiermann-uwd.7 — every permission the app uses has an iOS usage description.
///
/// **Why this cannot be caught any other way here.** iOS does not warn about a
/// missing `NS…UsageDescription`: it kills the process the instant the
/// permission is requested. So the app would crash the first time somebody
/// photographs a nest — on a device, in an attic — and App Store review rejects
/// the build before that anyway. This repo has no Mac and no Apple account, so
/// nothing in CI can build or run the iOS target at all; reading the source and
/// the plist is the whole of what is available.
///
/// The app shipped with NO usage descriptions and three permissions in use,
/// which is what this guard exists to have caught.
///
/// The mapping below is deliberately by CAPABILITY rather than by plugin name:
/// `image_picker` needs two different keys depending on which source a screen
/// offers, and a plugin swapped for another one asks for the same permission.
const _required = <String, ({String key, String why})>{
  // `photo_capture.dart` offers both the camera and the gallery, so both keys
  // are needed — offering one path and declaring the other is a crash on the
  // path that was not declared.
  'ImageSource.camera': (
    key: 'NSCameraUsageDescription',
    why: 'the area, nest and finding photos',
  ),
  'ImageSource.gallery': (
    key: 'NSPhotoLibraryUsageDescription',
    why: 'attaching an existing photo',
  ),
  // `device_location.dart`, through Geolocator. WhenInUse and not Always: this
  // app never wants a position while it is closed, and asking for Always is a
  // review rejection on its own.
  'Geolocator.getCurrentPosition': (
    key: 'NSLocationWhenInUseUsageDescription',
    why: 'opening the map where the reader is standing',
  ),
};

void main() {
  group('iOS permissions', () {
    late String plist;
    late String sources;

    setUpAll(() {
      plist = File(
        '${repoRoot.path}/apps/eiermann/ios/Runner/Info.plist',
      ).readAsStringSync();
      sources = [
        for (final file in sweptDartFiles()) file.readAsStringSync(),
      ].join('\n');
    });

    test('a permission the code requests is declared in Info.plist', () {
      final missing = <String>[];
      for (final entry in _required.entries) {
        // Only the permissions actually reached for. A description for
        // something unused is its own problem (below), not this one.
        if (!sources.contains(entry.key)) continue;
        if (!plist.contains('<key>${entry.value.key}</key>')) {
          missing.add(
            '${entry.value.key} — needed for ${entry.value.why} '
            '(`${entry.key}` is in the source)',
          );
        }
      }

      expect(
        missing,
        isEmpty,
        reason:
            'iOS kills the process when a permission is requested without its '
            'usage description, and review rejects the build first. Add it to '
            'ios/Runner/Info.plist, in German, saying what the app DOES with '
            'the permission.\n${missing.join('\n')}',
      );
    });

    test('a declared permission is one the app actually asks for', () {
      // The other direction. An undeclared-but-used permission crashes; a
      // declared-but-unused one is a prompt somebody is asked to accept for no
      // reason, and reviewers ask about it.
      final declared = RegExp(
        r'<key>(NS\w*UsageDescription)</key>',
      ).allMatches(plist).map((m) => m.group(1)!).toSet();

      final used = {
        for (final entry in _required.entries)
          if (sources.contains(entry.key)) entry.value.key,
      };

      expect(
        declared.difference(used),
        isEmpty,
        reason:
            'declared in Info.plist but nothing in lib/ asks for it. Either '
            'remove it, or add the capability to `_required` so the guard '
            'knows what uses it.',
      );
    });

    test('every description says something, not just the permission name', () {
      // Review rejects a description that restates the API ("Uses the camera").
      // A length floor is crude, but it catches the placeholder that arrives
      // with a plugin's README.
      final entries = RegExp(
        r'<key>NS\w*UsageDescription</key>\s*<string>([^<]*)</string>',
      ).allMatches(plist);

      expect(
        entries,
        isNotEmpty,
        reason:
            'no usage descriptions found at all — the regex or the plist '
            'shape changed, and this guard has been reading nothing',
      );
      for (final match in entries) {
        expect(
          match.group(1)!.trim().length,
          greaterThan(40),
          reason:
              'too short to say what the app does with the permission: '
              '"${match.group(1)}"',
        );
      }
    });

    test('the app never asks for a background location', () {
      // `NSLocationAlwaysAndWhenInUseUsageDescription` is a different review
      // conversation and a different privacy promise. This app wants a position
      // exactly while somebody is looking at a map, which is WhenInUse — and a
      // request for more is rejected on its own.
      expect(plist, isNot(contains('NSLocationAlwaysUsageDescription')));
      expect(
        plist,
        isNot(contains('NSLocationAlwaysAndWhenInUseUsageDescription')),
      );
    });
  });
}
