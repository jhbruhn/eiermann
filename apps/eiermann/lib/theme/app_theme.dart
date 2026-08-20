import 'package:flutter/material.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Eiermann's Material 3 theming.
///
/// The component shapes, the bundled font stack and the semantic-colour
/// extension all come from [ZugvogelTheme] — they are not brand. The one thing
/// this app supplies is [seed], which is what keeps its palette independent of
/// federfall's (injection boundary 2).
abstract final class AppTheme {
  /// Brand seed colour.
  ///
  /// A warm ochre yellow. It is the colour of the thing the work is about — an
  /// egg — and it reads as caution rather than alarm, which is the right
  /// register for a screen whose job is "this nest is due", not "something is
  /// wrong". Deliberately not a bright canary: at full saturation a yellow
  /// cannot carry legible dark text on it, and Material derives `onPrimary`
  /// from the seed.
  static const Color seed = Color(0xFFB8860B);

  static ThemeData get light =>
      ZugvogelTheme.build(seed: seed, brightness: Brightness.light);

  static ThemeData get dark =>
      ZugvogelTheme.build(seed: seed, brightness: Brightness.dark);
}
