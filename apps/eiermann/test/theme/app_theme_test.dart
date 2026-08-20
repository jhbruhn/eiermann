import 'package:eiermann/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

void main() {
  group('AppTheme', () {
    test('both brightnesses build and differ', () {
      expect(AppTheme.light.brightness, Brightness.light);
      expect(AppTheme.dark.brightness, Brightness.dark);
      expect(
        AppTheme.light.colorScheme.surface,
        isNot(AppTheme.dark.colorScheme.surface),
      );
    });

    test("the palette is this app's own, not the library's", () {
      // Injection boundary 2 from the app's side: zugvogel supplies the
      // component shapes and the font stack, this supplies the seed. A seed
      // that matched federfall's green would mean the boundary was not doing
      // anything.
      const federfallGreen = Color(0xFF356859);
      expect(AppTheme.seed, isNot(federfallGreen));
      expect(
        AppTheme.light.colorScheme.primary,
        isNot(
          ColorScheme.fromSeed(seedColor: federfallGreen).primary,
        ),
      );
    });

    test('the seed is a yellow — hue between 40 and 70 degrees', () {
      // Pinned because it is a product decision, not a detail: the colour of an
      // egg, and a caution register rather than an alarm one. A refactor that
      // quietly drifted this back towards green would change what the app FEELS
      // like with nothing failing.
      final hsl = HSLColor.fromColor(AppTheme.seed);
      expect(hsl.hue, greaterThan(40));
      expect(hsl.hue, lessThan(70));
    });

    test('...and dark enough to carry legible light text', () {
      // Material derives onPrimary from the seed. A full-saturation canary
      // yellow cannot carry either black or white text at contrast, which is
      // why the seed is an ochre.
      final scheme = ColorScheme.fromSeed(seedColor: AppTheme.seed);
      final contrast =
          scheme.onPrimary.computeLuminance() -
          scheme.primary.computeLuminance();
      expect(contrast.abs(), greaterThan(0.3));
    });

    test('ZugvogelSemantics is registered, so a chart finds a palette', () {
      for (final theme in [AppTheme.light, AppTheme.dark]) {
        final semantics = theme.extension<ZugvogelSemantics>();
        expect(semantics, isNotNull);
        expect(semantics!.categorical, isNotEmpty);
        expect(semantics.critical, theme.colorScheme.error);
      }
    });

    test('the bundled font stack is applied', () {
      // Web has no system fonts: an uncovered codepoint makes the engine fetch
      // a Noto slice, the CSP blocks it, and it retries on every layout
      // (federfall-sbtx). The families have to be NAMED here, not merely
      // bundled.
      for (final theme in [AppTheme.light, AppTheme.dark]) {
        expect(
          theme.textTheme.bodyMedium?.fontFamily,
          ZugvogelTheme.fontFamily,
        );
        expect(
          theme.textTheme.bodyMedium?.fontFamilyFallback,
          ZugvogelTheme.fontFallbacks,
        );
      }
    });
  });
}
