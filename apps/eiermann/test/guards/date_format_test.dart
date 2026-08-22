import 'package:flutter_test/flutter_test.dart';
import 'package:zugvogel_ui/testing.dart';

import 'sweep_sources.dart';

/// Files that may name a date formatter without going through
/// `formatLocalDate`, each with the reason it is here.
///
/// This list is the whole point of the guard: an entry is a decision somebody
/// wrote down, not a way to make the test quiet. Adding one without a reason
/// next to it is the failure mode this exists to prevent.
const _allowed = <String>[
  // Zugvogel's own — the one widget allowed to render a date, and the sweep
  // itself, which cannot not match the pattern it searches for.
  ...defaultDateFormattingAllowlist,

  // Two month-NAME lookups, not date formatting. `DateFormat.MMMM` /
  // `DateFormat.MMM` is called on `DateTime(2000, month)` to turn a number 1-12
  // into the locale's word for it: MaterialLocalizations has no bare-month
  // format, and slicing a name out of a full date depends on the locale's field
  // order. The statement-level `DateTime(` exemption in the shared sweep
  // already covers those two calls — these entries are belt and braces for the
  // day somebody lifts the lookup into a variable, and the note is here so the
  // lift is a conscious act.
  'features/statistics/period_selector.dart',
  'features/statistics/egg_series_chart.dart',
];

void main() {
  group('date formatting', () {
    test('formatLocalDate is the only date formatter in the workspace', () {
      // PocketBase timestamps are UTC and neither DateFormat nor
      // MaterialLocalizations converts. In CET everything logged after 22:00
      // UTC renders as the previous day — invisible on a UTC CI machine, and it
      // reaches users one screen at a time. Nine of these shipped in federfall
      // before anyone connected them to each other.
      //
      // A per-screen test cannot hold this: the screen written next month is
      // where it comes back. So the guard reads the source, including source
      // that does not exist yet.
      final offenders = [
        for (final root in sweptLibRoots)
          ...rawDateFormattingOffenders(root, allowlist: _allowed),
      ];
      expect(
        offenders,
        isEmpty,
        reason:
            'Route the conversion through formatLocalDate, or add the file to '
            '_allowed WITH the reason it belongs there.',
      );
    });

    test('...and the sweep read files at all', () {
      // A sweep over nothing passes over anything. This is the canary for the
      // path arithmetic in sweep_sources.dart: `flutter test` runs from the app
      // directory, and a wrong repo root would make every guard in this
      // directory green while reading an empty tree.
      final files = sweptDartFiles().toList();
      expect(
        files.length,
        greaterThan(100),
        reason: 'sweptLibRoots resolved to ${sweptLibRoots.map((d) => d.path)}',
      );
      // ...and all three members contributed, not just the app.
      for (final member in sweptMembers) {
        expect(
          files.any((f) => relative(f).startsWith('$member/lib/')),
          isTrue,
          reason: 'no file swept from $member',
        );
      }
    });
  });
}
