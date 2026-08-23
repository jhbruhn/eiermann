@Tags(['guard'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'sweep_sources.dart';

/// eiermann-uwd.8 — every user-facing string is in the ARB files, in BOTH
/// languages.
///
/// Two halves, and each one alone would pass while the other is broken:
///
///   * a string can be missing from the ARB because it was written inline in a
///     widget, which no localisation tooling notices at all;
///   * a string can be in the German template and absent from the English file,
///     which gen-l10n handles by emitting the TEMPLATE text. That is the nasty
///     one — the app builds, every test passes, and an English reader gets
///     German. It is exactly how `app_en.arb` came to be 174 keys behind
///     without a single failing build.
///
/// So the parity check reads the ARB JSON directly rather than going through
/// the generated getters, which would answer with the fallback and prove
/// nothing.

/// Files that may hold a user-facing literal, each with the reason.
///
/// The list is the point of the guard, not a way to make it quiet: an entry is
/// a decision somebody wrote down. Adding one without a reason beside it is the
/// failure mode this exists to prevent.
const _allowed = <String>[
  // The ARB bridge itself: every line is `_l10n.someKey`, and the class doc
  // quotes wire values (`spot_phase_needs_permitted`) to say what maps to what.
  'l10n/l10n.dart',

  // Wire values, not prose. These map a stored string to an ARB key, so the
  // literals in them are the SERVER's vocabulary — `closed`, `coordinator`,
  // `feral_pigeon`. Translating them would be translating the database.
  'features/audit/audit_labels.dart',

  // The instance's own name and the service marker, neither of which is
  // language-dependent: "Eiermann" is "Eiermann" in every locale.
  'config/app_environment.dart',
  'config/zugvogel_bindings.dart',
];

/// A literal that is prose rather than a key, an identifier or a format.
///
/// Deliberately narrow. It looks only at the arguments a user actually READS —
/// `Text(...)`, `label:`, `title:`, `hintText:`, `tooltip:`, `message:` — and
/// only flags a literal that looks like a SENTENCE: at least two words, or one
/// word starting with a capital. A single lower-case token is an id, a route,
/// an icon name or a wire value, and flagging those would make the guard noise
/// that gets an allowlist entry rather than a fix.
final _proseArgument = RegExp(
  '(?:Text|label|title|hintText|helperText|tooltip|message|labelText|'
  'semanticLabel|placeholder)'
  // The captured literal must contain no `\$`: an interpolated string is
  // composed at runtime and its parts are already localised, so flagging one
  // would report the join rather than the copy.
  r'''\s*[:(]\s*'([^'$]{2,})'''
  // The closing quote of the captured literal, split off because a `'''` raw
  // string cannot end on the very quote character it is matching.
  "'",
);

/// Whether [literal] reads as something a person would be shown.
bool _isProse(String literal) {
  final text = literal.trim();
  if (text.isEmpty) return false;
  // A path, a route, a wire value, an asset key: never prose.
  if (RegExp(r'^[a-z0-9_/.:-]+$').hasMatch(text)) return false;
  // A format string, a symbol, a single punctuation mark.
  if (!RegExp('[A-Za-zÄÖÜäöüß]').hasMatch(text)) return false;
  final words = text.split(RegExp(r'\s+'));
  if (words.length >= 2) return true;
  return RegExp('^[A-ZÄÖÜ]').hasMatch(text);
}

Map<String, dynamic> _arb(String name) =>
    jsonDecode(
          File(
            '${repoRoot.path}/apps/eiermann/lib/l10n/arb/$name',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

Set<String> _keys(Map<String, dynamic> arb) =>
    arb.keys.where((key) => !key.startsWith('@')).toSet();

void main() {
  group('localisation', () {
    test('both ARB files carry exactly the same keys', () {
      // German is the gen-l10n TEMPLATE, not a translation of an English
      // original — every string in this app is written in German first, because
      // that is the language the people using it speak in the field. So the
      // template is the authority on which keys exist, and English is measured
      // against it.
      final de = _arb('app_de.arb');
      final en = _arb('app_en.arb');

      final missing = (_keys(de)..removeAll(_keys(en))).toList()..sort();
      final extra = (_keys(en)..removeAll(_keys(de))).toList()..sort();

      expect(
        missing,
        isEmpty,
        reason:
            'in the German template and absent from app_en.arb. gen-l10n does '
            'NOT fail on this — it emits the template string, so the app '
            'and shows German to an English reader.',
      );
      expect(
        extra,
        isEmpty,
        reason:
            'in app_en.arb with no counterpart in the template. Either the key '
            'was renamed on one side only, or a string was deleted from German '
            'and left in English — both leave dead copy behind.',
      );
    });

    test('every declared placeholder survives into the translation', () {
      // A translation that drops `{count}` compiles and then renders a sentence
      // with the number missing. gen-l10n does not check this either.
      final de = _arb('app_de.arb');
      final en = _arb('app_en.arb');

      final offenders = <String>[];
      for (final key in _keys(de)) {
        final meta = de['@$key'];
        if (meta is! Map || meta['placeholders'] is! Map) continue;
        final names = (meta['placeholders'] as Map).keys.map((k) => '$k');
        final english = '${en[key]}';
        for (final name in names) {
          final used =
              english.contains('{$name}') ||
              RegExp('\\{$name\\s*,').hasMatch(english);
          if (!used) offenders.add('$key drops {$name}');
        }
      }

      expect(offenders, isEmpty, reason: offenders.join('; '));
    });

    test('the ARB files hold no empty strings', () {
      // An empty value is worse than a missing key: the key exists, so the
      // parity check above is satisfied, and the app renders a blank label.
      for (final name in ['app_de.arb', 'app_en.arb']) {
        final arb = _arb(name);
        final blank = [
          for (final key in _keys(arb))
            if ('${arb[key]}'.trim().isEmpty) key,
        ];
        expect(blank, isEmpty, reason: '$name: $blank');
      }
    });

    test('no user-facing string is written inline in the source', () {
      // The half no localisation tool can see. A `Text('Gespeichert')` is not a
      // missing translation — it is a string that was never offered for
      // translation at all, and it renders identically in both locales while
      // looking perfectly correct in review.
      final offenders = <String>[];
      for (final file in sweptDartFiles(allowlist: _allowed)) {
        final source = file.readAsStringSync();
        for (final line in const LineSplitter().convert(source)) {
          final trimmed = line.trimLeft();
          // Comments quote copy constantly — that is how this codebase
          // explains itself — and a doc comment is not something a user reads.
          if (trimmed.startsWith('//') || trimmed.startsWith('///')) continue;
          if (trimmed.startsWith('*')) continue;
          for (final match in _proseArgument.allMatches(line)) {
            final literal = match.group(1)!;
            if (_isProse(literal)) {
              offenders.add('${relative(file)}: "$literal"');
            }
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'Move it into app_de.arb and app_en.arb and read it through '
            '`context.l10n`, or add the file to _allowed WITH the reason. '
            'Found:\n${offenders.join('\n')}',
      );
    });

    test('the sweep reads files at all', () {
      // A sweep over nothing passes over anything — and this one filters
      // hard enough that a wrong root would look exactly like a clean codebase.
      expect(sweptDartFiles(allowlist: _allowed).length, greaterThan(50));
    });

    test('the prose test can tell prose from an identifier', () {
      // The canary for the filter itself. If `_isProse` said no to everything,
      // the sweep above would pass over an app full of hardcoded German.
      expect(_isProse('Besuch abschließen'), isTrue);
      expect(_isProse('Gespeichert'), isTrue);
      expect(_isProse('Nothing was saved'), isTrue);
      // ...and yes to nothing that is merely an identifier or a format.
      expect(_isProse('spot_phase_changed'), isFalse);
      expect(_isProse('assets/images/dohle.png'), isFalse);
      expect(_isProse('de'), isFalse);
      expect(_isProse('yyyy-MM-dd'), isFalse);
      expect(_isProse('  '), isFalse);
      expect(_isProse('→'), isFalse);
    });
  });
}
