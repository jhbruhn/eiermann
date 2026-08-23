@Tags(['guard'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'sweep_sources.dart';

/// Every permission the app needs is in the MAIN Android manifest.
///
/// **Why the main one specifically.** Flutter's template declares
/// `android.permission.INTERNET` in `src/debug` and `src/profile` only — those
/// exist for the tool's own VM-service channel, not for the app. The merged
/// manifest of a RELEASE build therefore has no network permission at all
/// unless the app declares it here, and this app is a PocketBase client:
/// without it every request dies before DNS and the app looks like it cannot
/// reach a server that is up and answering. federfall shipped exactly this bug
/// first (see its manifest comment); this one shipped it second, which is why
/// the property is now a test rather than a comment.
///
/// The guard reads the manifest that ships, so a plugin's merged-in permission
/// does not count — none of this app's plugins declares INTERNET, and relying
/// on one that might is how the permission disappears again in a dependency
/// bump.
const _required = <String, ({String permission, String why})>{
  // Not a source marker but a constant condition: this app has no offline
  // mode. Every screen is a call to PocketBase.
  '': (
    permission: 'android.permission.INTERNET',
    why: 'the app is a PocketBase client and has no offline mode',
  ),
  // Mirrors the iOS mapping in `ios_permissions_test.dart`: the same call site,
  // the other platform. Android refuses a runtime request for an undeclared
  // permission WITHOUT showing a dialog, which is indistinguishable from a user
  // who said no.
  'Geolocator.getCurrentPosition': (
    permission: 'android.permission.ACCESS_FINE_LOCATION',
    why: 'opening the map where the reader is standing',
  ),
};

void main() {
  group('Android permissions', () {
    late String manifest;
    late String sources;

    setUpAll(() {
      manifest = File(
        '${repoRoot.path}/apps/eiermann/android/app/src/main/'
        'AndroidManifest.xml',
      ).readAsStringSync();
      sources = [
        for (final file in sweptDartFiles()) file.readAsStringSync(),
      ].join('\n');
    });

    test('a permission the app needs is declared in the main manifest', () {
      final missing = <String>[];
      for (final entry in _required.entries) {
        if (entry.key.isNotEmpty && !sources.contains(entry.key)) continue;
        if (!manifest.contains('android:name="${entry.value.permission}"')) {
          missing.add('${entry.value.permission} — ${entry.value.why}');
        }
      }

      expect(
        missing,
        isEmpty,
        reason:
            'declared in src/debug and src/profile only, a permission is '
            'absent from every build a user installs. Add it to '
            'android/app/src/main/AndroidManifest.xml.\n${missing.join('\n')}',
      );
    });

    test('the app never asks for a background location', () {
      // The counterpart of the iOS guard's last case: this app wants a position
      // exactly while somebody is looking at a map.
      expect(
        manifest,
        isNot(contains('android.permission.ACCESS_BACKGROUND_LOCATION')),
      );
    });
  });
}
