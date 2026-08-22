import 'package:flutter_test/flutter_test.dart';
import 'package:zugvogel_ui/testing.dart';

import 'sweep_sources.dart';

void main() {
  group('paging', () {
    test('nothing asks for a numbered page', () {
      // `?page=2` over a list that grows while it is being read skips rows and
      // repeats others: every record written between the two requests shifts
      // the window by one. Nests and Spots are added by the same people who are
      // scrolling the list, so the window shifts constantly, and the reader
      // sees a Spot twice and never sees the one it displaced.
      //
      // `page: 1` is the keyset spelling and is allowed: the position comes
      // from the cursor in the filter, and the page number stays pinned at the
      // top of whatever that filter selected.
      final offenders = <String>[];
      for (final file in sweptDartFiles()) {
        final lines = stripComments(file.readAsStringSync()).split('\n');
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          // Captured and compared rather than excluded with a lookahead:
          // `\s*` backtracks to nothing, so `(?!1)` reads the space and passes
          // on the one spelling that is allowed. Measured — this guard's own
          // first version reported `page: 1,`.
          final page = RegExp(r'\bpage:\s*([^\s,)]+)').firstMatch(line);
          if ((page != null && page.group(1) != '1') ||
              RegExp("['\"][^'\"]*[?&]page=").hasMatch(line)) {
            offenders.add('${relative(file)}:${i + 1}  ${line.trim()}');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'Page by keyset: pin page to 1 and resume from a cursor in the '
            'filter. See SpotOverviewRepository.dueFirst.',
      );
    });

    test('every debounce is the one named constant', () {
      // Not "searches are debounced" — that is not checkable about a screen
      // nobody has written yet. What is checkable, and is the property that
      // actually decays, is that there is ONE value. Two screens searching the
      // same query with 300 ms and 500 ms make "has the list caught up yet"
      // depend on which screen you are looking at, and the second value is
      // always added by somebody who did not know about the first.
      final offenders = <String>[];
      for (final file in sweptDartFiles()) {
        final source = stripComments(file.readAsStringSync());
        for (final match in RegExp(
          r'(?:Timer|\.delayed)\(\s*(?:const\s+)?Duration\(',
        ).allMatches(source)) {
          offenders.add(
            '${relative(file)}: ${source.substring(match.start, match.end)}…',
          );
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'Name the duration — kSpotSearchDebounce for a search field — so '
            'there is one value to change.',
      );
    });

    test('a paged search tells "nothing yet" from "nothing matching"', () {
      // A list that pages AND filters has two empty states, and they need
      // different words: an org with no Spots at all is offered the button that
      // creates one, while a search with no hit is told to try another term.
      // Collapsing them shows "Noch keine Spots" to somebody looking at a
      // typo — and the empty state is exactly where a reader decides the app
      // is broken.
      final offenders = <String>[];
      var swept = 0;
      for (final file in sweptDartFiles()) {
        final source = stripComments(file.readAsStringSync());
        if (!source.contains('PagedListTail')) continue;
        if (!source.contains('Debounce')) continue;
        swept++;
        // The two branches have to be visible: an EmptyView chosen by whether
        // the query narrows anything.
        if (!RegExp(r'_query[^\n]*isEmpty').hasMatch(source)) {
          offenders.add(relative(file));
        }
      }
      expect(offenders, isEmpty, reason: 'branch the EmptyView on the query');
      expect(
        swept,
        greaterThan(0),
        reason: 'a sweep over nothing passes over anything',
      );
    });

    test('...and the sweep found paged reads at all', () {
      final paged = sweptDartFiles()
          .where((f) => f.readAsStringSync().contains('perPage'))
          .length;
      expect(
        paged,
        greaterThan(1),
        reason: 'a sweep over nothing passes over anything',
      );
    });
  });
}
