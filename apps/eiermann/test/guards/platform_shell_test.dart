@Tags(['guard'])
library;

import 'dart:io';

import 'package:eiermann/l10n/l10n.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sweep_sources.dart';

/// Properties of the two native shells that are neither permissions nor Dart,
/// and that no Dart test would otherwise reach.
///
/// **Why these need a guard at all.** Both files started as Flutter's template
/// and are regenerated or hand-edited rarely enough that a lost line goes
/// unnoticed for months — and neither failure shows up in a debug build on a
/// developer's machine. This repo has no Mac and no Apple account, so nothing
/// in CI builds the iOS target; reading the shipped files is the whole of what
/// is available, exactly as in `ios_permissions_test.dart`.
void main() {
  group('iOS bundle localisations', () {
    late String plist;

    setUpAll(() {
      plist = File(
        '${repoRoot.path}/apps/eiermann/ios/Runner/Info.plist',
      ).readAsStringSync();
    });

    test('CFBundleLocalizations lists exactly the locales the app ships', () {
      // Without the key iOS takes the bundle for monolingual in its development
      // region — `en`, from the Xcode project's `developmentRegion` — and
      // filters the preferred-language list it hands the app down to that one
      // entry. `localeListResolutionCallback` then never sees the German a
      // German device asked for, and the app starts in English although German
      // is the design language and `app_de.arb` is the gen-l10n TEMPLATE.
      //
      // Read out of the plist rather than merely asserted present, because the
      // key falling BEHIND `supportedLocales` fails the same way for whichever
      // locale is missing: a third language added to the ARB set and not here
      // is unreachable on iOS.
      final declared = RegExp(
        r'<key>CFBundleLocalizations</key>\s*<array>(.*?)</array>',
        dotAll: true,
      ).firstMatch(plist)?.group(1);

      expect(
        declared,
        isNotNull,
        reason:
            'no CFBundleLocalizations array in ios/Runner/Info.plist. iOS '
            'reports only the development region to the app, so a German '
            'device gets the English strings.',
      );

      final listed = RegExp(
        '<string>([^<]*)</string>',
      ).allMatches(declared!).map((m) => m.group(1)!.trim()).toSet();
      final shipped = {
        for (final locale in AppLocalizations.supportedLocales)
          locale.languageCode,
      };

      expect(
        listed,
        shipped,
        reason:
            'CFBundleLocalizations and AppLocalizations.supportedLocales have '
            'drifted. Anything in supportedLocales but not the plist is a '
            'language iOS will not resolve to; anything in the plist but not '
            'supportedLocales is a claim the bundle cannot honour.',
      );
    });
  });

  group('Android backup', () {
    late String manifest;

    setUpAll(() {
      manifest = File(
        '${repoRoot.path}/apps/eiermann/android/app/src/main/'
        'AndroidManifest.xml',
      ).readAsStringSync();
    });

    test('Auto Backup is switched off', () {
      // The server is the only source of truth, and the three things this app
      // does put on disk — the auth token in flutter_secure_storage,
      // shared_preferences and the image cache — would all be copied by Auto
      // Backup or a device transfer onto a device that never authenticated,
      // outside PocketBase's access control. The token would not even work
      // there: its key lives in the Android Keystore, which is not part of the
      // backup. `allowBackup` DEFAULTS TO TRUE, so the absent attribute is the
      // dangerous state and its presence has to be asserted rather than its
      // absence.
      expect(
        manifest,
        contains('android:allowBackup="false"'),
        reason:
            'android:allowBackup defaults to true. Without this attribute the '
            'auth token and the local caches leave the device with Auto Backup '
            'and device transfer. Nothing is lost by disabling it — a fresh '
            'install re-fetches everything at login.',
      );
    });
  });
}
