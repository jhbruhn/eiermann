@Tags(['guard'])
library;

import 'dart:convert';

import 'package:eiermann/theme/app_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

import 'sweep_sources.dart';

/// eiermann-uwd.5 — nothing names a font family the app does not bundle.
///
/// **Why this is a guard.** Web has no system fonts. A `TextStyle` naming a
/// family that is not bundled does not fall back to something reasonable: the
/// engine resolves the missing codepoints by downloading a per-glyph Noto slice
/// from `fonts.gstatic.com`, the app's own CSP (`font-src 'self'`) blocks it,
/// and it retries **on every layout of that text**. A deployed federfall
/// instance produced an endless stream of console errors from a single arrow in
/// a single string.
///
/// It is invisible locally in three separate ways: `flutter run` on Linux or
/// Android has real system fonts, a widget test has a stub font answering for
/// every glyph, and the CSP is a server header the dev stack need not apply.
/// So the only thing that catches it early is reading the source — including
/// source that does not exist yet.
///
/// This guard was written after `invite_sheet.dart` shipped a monospace
/// `fontFamily` for exactly the readability reason that sounds harmless —
/// in the same phase whose own issue is about verifying the CSP.
const _allowed = <String>[
  // The theme is where the bundled family is NAMED, by delegating to
  // ZugvogelTheme — which is the correct and only place.
  'theme/app_theme.dart',
];

void main() {
  group('fonts', () {
    test('the bundled families are the only ones anything names', () {
      // What the app actually ships, as the engine sees it: zugvogel_ui carries
      // the assets, so every family is prefixed `packages/zugvogel_ui/`.
      final bundled = {
        ZugvogelTheme.fontFamily,
        ...ZugvogelTheme.fontFallbacks,
      };

      // `fontFamily: '…'` and `fontFamilyFallback: [...]` with a literal in it.
      final named = RegExp(
        r"""fontFamily(?:Fallback)?\s*:\s*\[?\s*'([^']+)'""",
      );

      final offenders = <String>[];
      for (final file in sweptDartFiles(allowlist: _allowed)) {
        for (final line in const LineSplitter().convert(
          file.readAsStringSync(),
        )) {
          final trimmed = line.trimLeft();
          // Comments discuss this constantly — including the one that
          // explains why a monospace family was wrong.
          if (trimmed.startsWith('//') || trimmed.startsWith('*')) continue;
          for (final match in named.allMatches(line)) {
            final family = match.group(1)!;
            if (!bundled.contains(family)) {
              offenders.add('${relative(file)}: "$family"');
            }
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'Not a cosmetic problem: on web the engine tries to DOWNLOAD the '
            'missing glyphs, the CSP blocks it, and it retries on every layout '
            'forever. Use ZugvogelTheme.fontFamily / .fontFallbacks, or bundle '
            'the font and add it there.\nFound:\n${offenders.join('\n')}',
      );
    });

    test('the theme really does name a bundled family', () {
      // The other half. A sweep proving nothing names a WRONG family would pass
      // just as happily over an app that names no family at all — and the M3
      // default is not the bundled Roboto, so the fallbacks would hang off
      // nothing.
      final theme = AppTheme.light;
      expect(theme.textTheme.bodyMedium?.fontFamily, ZugvogelTheme.fontFamily);
      expect(
        theme.textTheme.bodyMedium?.fontFamilyFallback,
        ZugvogelTheme.fontFallbacks,
      );
      expect(
        ZugvogelTheme.fontFallbacks,
        isNotEmpty,
        reason: 'no fallbacks bundled at all — every symbol becomes a download',
      );
    });

    test('the sweep can tell an unbundled family from a bundled one', () {
      // The canary for the check itself, without editing a real file: the
      // bundled set has to actually contain the prefixed names, or the
      // comparison above would flag everything or nothing.
      expect(ZugvogelTheme.fontFamily, startsWith('packages/zugvogel_ui/'));
      expect(
        {ZugvogelTheme.fontFamily}.contains('monospace'),
        isFalse,
        reason: 'the sweep must consider `monospace` unbundled',
      );
    });
  });
}
