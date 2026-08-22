import 'package:flutter_test/flutter_test.dart';
import 'package:zugvogel_ui/testing.dart';

import 'sweep_sources.dart';

void main() {
  group('enums', () {
    test('every enum either carries a wire value or says why it does not', () {
      // A bare Dart enum serialises by `name`, so renaming a value — a
      // refactor, in every reviewer's eyes — silently changes what the client
      // writes into a PocketBase select field. The record then holds a value
      // the server's own select does not list, and the next reader gets null.
      //
      // `implements WireEnum` makes the stored string an explicit, separate
      // decision from the identifier, so a rename is wire-safe. The escape
      // hatch is a doc line, not an allowlist in this file, because the reason
      // belongs where the next person is tempted to add a value: the enum
      // itself.
      final offenders = <String>[];
      var checked = 0;
      for (final file in sweptDartFiles()) {
        final source = stripComments(file.readAsStringSync());
        for (final match in RegExp(
          r'^enum\s+(\w+)([^{]*)\{',
          multiLine: true,
        ).allMatches(source)) {
          checked++;
          final name = match.group(1)!;
          if (match.group(2)!.contains('WireEnum')) continue;
          // The doc comment sits above the declaration, and stripComments
          // blanked it — so the exemption is read from the raw source, and from
          // the CONTIGUOUS `///` block directly above this enum and no further.
          //
          // The first version of this took everything before the declaration,
          // which meant the first exempted enum in a file exempted every enum
          // after it. The canary found that in one run: a bare `enum
          // CanaryState { a, b }` appended below TourStopState passed.
          // Either spelling of the marker. `[WireEnum]` where the type is
          // imported, `` `WireEnum` `` where it is not — a doc reference to a
          // type that is not in scope is an analyzer finding, and adding an
          // import for a comment is the wrong trade.
          if (RegExp('Not a .?WireEnum.?:').hasMatch(
            _docBlockAbove(file.readAsStringSync(), name),
          )) {
            continue;
          }
          offenders.add('${relative(file)}: enum $name');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'Add `implements WireEnum` with an explicit wire string, or write '
            '"Not a WireEnum:" in the doc comment WITH the reason nothing '
            'stores it.',
      );
      expect(
        checked,
        greaterThan(15),
        reason: 'a sweep over nothing passes over anything',
      );
    });
  });
}

/// The contiguous `///` doc block immediately above `enum [name]` in [source].
///
/// Contiguous is the whole point: a blank line or a line of code ends the
/// block, so an exemption written for one enum cannot be read as covering the
/// next one.
String _docBlockAbove(String source, String name) {
  final lines = source.split('\n');
  final at = lines.indexWhere(
    (line) => RegExp('^enum\\s+$name\\b').hasMatch(line),
  );
  if (at < 0) return '';
  final block = <String>[];
  for (var i = at - 1; i >= 0; i--) {
    if (!lines[i].trimLeft().startsWith('///')) break;
    block.add(lines[i]);
  }
  return block.join('\n');
}
