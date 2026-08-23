@Tags(['guard'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'sweep_sources.dart';

/// eiermann-uwd.5 — every character the app displays is in a bundled font.
///
/// **Why an allowlist and not a coverage check.** The honest check is to read
/// the `cmap` of each bundled TTF, and that is exactly how this list was
/// produced — but a TTF parser in a widget test is a lot of machinery to keep
/// working, and this is a list that changes a few times a year. So the
/// verification is a command somebody re-runs when adding a character, and the
/// list is what CI enforces.
///
/// Re-run it like this, from the repo root, when adding an entry:
///
/// ```sh
/// python3 - <<'PY'
/// import json, glob
/// from fontTools.ttLib import TTFont
/// zv = glob.glob(f"{glob.os.environ['HOME']}/.pub-cache/git/zugvogel-*/"
///                "packages/zugvogel_ui/assets/fonts/*.ttf")
/// cov = {}
/// for p in zv:
///     f = TTFont(p, fontNumber=0, lazy=True)
///     cov[p.split('/')[-1]] = set().union(*(set(t.cmap) for t in f['cmap'].tables))
/// for fn in ('app_de.arb', 'app_en.arb'):
///     d = json.load(open(f'apps/eiermann/lib/l10n/arb/{fn}'))
///     for k, v in d.items():
///         if k.startswith('@') or not isinstance(v, str): continue
///         for ch in v:
///             if ord(ch) < 128: continue
///             if not [n for n, c in cov.items() if ord(ch) in c]:
///                 print(f'NOT COVERED: U+{ord(ch):04X} {ch!r} {fn}:{k}')
/// PY
/// ```
///
/// **What happens without this.** Web has no system fonts. A codepoint no
/// bundled family covers makes the engine download a per-glyph Noto slice from
/// `fonts.gstatic.com`; the app's own CSP (`font-src 'self'`) blocks it, and it
/// retries on every layout of that text. One arrow in one string produced an
/// endless console error stream on a deployed federfall instance — and the
/// character renders as a box for the reader either way.
///
/// It cannot be caught anywhere else: a widget test renders with a stub font
/// that answers for every glyph, and `flutter run` on Linux or Android has real
/// system fonts behind it.
///
/// Verified against the bundled files on 2026-08-23: Roboto covers the German
/// alphabet, the dashes, the German and English quotation marks, the ellipsis,
/// `§`, `·`, `×` and `Ø`; `→` comes from Noto Sans Symbols, which is precisely
/// why the fallback list exists.
const _covered = <int>{
  // ── German, from Roboto ──
  0x00C4, // Ä
  0x00D6, // Ö
  0x00DC, // Ü
  0x00E4, // ä
  0x00F6, // ö
  0x00FC, // ü
  0x00DF, // ß
  // ── Punctuation this codebase's copy actually uses, from Roboto ──
  0x2013, // – en dash
  0x2014, // — em dash, the house style for an aside
  0x201C, // “ English opening quote
  0x201D, // ” English closing quote
  0x201E, // „ German opening quote
  0x2026, // … ellipsis
  0x00B7, // · middle dot, the separator in a two-part label
  0x00A7, // § as in §44 BNatSchG
  0x00D7, // × as in "3× nichts gefunden"
  0x00D8, // Ø as in a diameter
  // ── From Noto Sans Symbols, NOT Roboto ──
  // The one that is not merely decorative history: an arrow of exactly this
  // kind is what produced the federfall error stream. It is safe here only
  // because `ZugvogelTheme.fontFallbacks` names the family that carries it.
  0x2192, // → in the audit log's "from → to"
};

void main() {
  group('glyph coverage', () {
    /// Every non-ASCII codepoint in a locale's copy, with where it came from.
    Map<int, List<String>> nonAsciiIn(String arbFile) {
      final arb =
          jsonDecode(
                File(
                  '${repoRoot.path}/apps/eiermann/lib/l10n/arb/$arbFile',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;

      final found = <int, List<String>>{};
      for (final entry in arb.entries) {
        // `@key` blocks are developer notes, never rendered.
        if (entry.key.startsWith('@')) continue;
        final value = entry.value;
        if (value is! String) continue;
        for (final rune in value.runes) {
          if (rune > 127) (found[rune] ??= []).add(entry.key);
        }
      }
      return found;
    }

    for (final arbFile in ['app_de.arb', 'app_en.arb']) {
      test('$arbFile uses no character the app cannot draw', () {
        final found = nonAsciiIn(arbFile);
        String describe(int rune, List<String> keys) {
          final hex = rune.toRadixString(16).toUpperCase().padLeft(4, '0');
          final where = keys.take(3).join(', ');
          return 'U+$hex "${String.fromCharCode(rune)}" in $where';
        }

        final uncovered = [
          for (final entry in found.entries)
            if (!_covered.contains(entry.key)) describe(entry.key, entry.value),
        ];

        expect(
          uncovered,
          isEmpty,
          reason:
              'A codepoint no bundled font covers is a box on web AND an '
              'endless retry against fonts.gstatic.com that the CSP blocks. '
              'Check coverage with the command in this file, then add it to '
              '_covered — or use a character that is already there.\n'
              '${uncovered.join('\n')}',
        );
      });
    }

    test('the allowlist has no entries the copy stopped using', () {
      // A stale entry is not harmful, but it is a claim nobody checked. The
      // list is meant to be the set of characters this app actually draws.
      final used = <int>{
        ...nonAsciiIn('app_de.arb').keys,
        ...nonAsciiIn('app_en.arb').keys,
      };
      final stale = _covered.difference(used).toList()..sort();
      expect(
        stale.map(
          (cp) =>
              'U+${cp.toRadixString(16).toUpperCase()} '
              '"${String.fromCharCode(cp)}"',
        ),
        // Ö is the one deliberate exception: it belongs to the German alphabet
        // and its absence today is an accident of which words got written, not
        // a decision. Every other unused entry should go.
        anyOf(isEmpty, equals(['U+D6 "Ö"'])),
        reason: 'listed as covered but nothing uses it any more',
      );
    });

    test('the sweep found characters to check at all', () {
      // A sweep over nothing passes over anything — and this one reads a path,
      // so a wrong repo root would look exactly like flawless ASCII copy.
      expect(nonAsciiIn('app_de.arb').length, greaterThan(5));
    });
  });
}
