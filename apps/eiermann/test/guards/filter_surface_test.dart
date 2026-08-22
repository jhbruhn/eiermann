import 'package:flutter_test/flutter_test.dart';
import 'package:zugvogel_ui/testing.dart';

import 'sweep_sources.dart';

/// Call sites that build a filter expression from something other than a
/// literal, each with the reason it is allowed to.
///
/// An entry is a decision, not a way to silence the guard. It says: the thing
/// being interpolated is an IDENTIFIER the code chose, never a VALUE a user
/// typed — values go through the parameter map, always.
const _allowedInterpolation = <String>[
  // `anyOf(field, values)` builds `field = {:v0} || field = {:v1} …` because
  // PocketBase has no IN operator. `$field` is a column name from the call
  // site (both callers pass the literal 'visit') and `$index` is a loop
  // counter; every VALUE is bound through `params`.
  'repositories/history_repositories.dart',
];

void main() {
  group('the query surface', () {
    test('nothing interpolates into a filter expression', () {
      // The type system already stops the obvious version of this: the query
      // surface accepts only `PbFilter`, and the only way to make one is
      // `filterExpr`. What it cannot stop is interpolating into the expression
      // handed TO filterExpr — `filterExpr('name ~ "$query"')` compiles, type
      // checks, and is the same filter injection with an extra step.
      //
      // So the guard reads the argument. A `$` in there is either a const
      // fragment being composed (fine, and checked) or a value that belongs in
      // the parameter map (not fine, and named here).
      final offenders = <String>[];
      for (final file in sweptDartFiles(allowlist: _allowedInterpolation)) {
        final source = stripComments(file.readAsStringSync());
        final consts = RegExp(
          r'const\s+(?:\w+\s+)?(\w+)\s*=',
        ).allMatches(source).map((m) => m.group(1)!).toSet();
        for (final argument in _filterExprArguments(source)) {
          for (final match in RegExp(r'\$\{?(\w*)').allMatches(argument)) {
            final name = match.group(1)!;
            if (name.isNotEmpty && consts.contains(name)) continue;
            offenders.add('${relative(file)}: filterExpr(… $argument …)');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            "Bind the value as a parameter — filterExpr('x = {:v}', "
            "{'v': value}) — instead of writing it into the expression.",
      );
    });

    test('no raw string reaches a filter argument', () {
      // `PbReadOnlyRepository.list` takes a `PbFilter`, so this cannot happen
      // there. It can happen one level down: a repository that reaches past the
      // typed surface into the raw `RecordService` — which
      // `SpotOverviewRepository.dueFirst` legitimately does, because a keyset
      // cursor over a computed column needs an int-bound parameter — takes a
      // `String?` again, and the type safety is gone with it.
      final offenders = <String>[];
      for (final file in sweptDartFiles()) {
        for (final statement in stripComments(
          file.readAsStringSync(),
        ).split(';')) {
          if (!RegExp(r'''filter:\s*['"]''').hasMatch(statement)) continue;
          offenders.add('${relative(file)}: ${statement.trim()}');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'Pass a PbFilter from filterExpr, not a string.',
      );
    });

    test('...and the sweep found filters to check at all', () {
      final calls = [
        for (final file in sweptDartFiles())
          ..._filterExprArguments(stripComments(file.readAsStringSync())),
      ];
      expect(
        calls.length,
        greaterThan(10),
        reason: 'a sweep over nothing passes over anything',
      );
    });
  });
}

/// The argument text of every `filterExpr(…)` call in [source].
///
/// Scanned with a paren counter rather than a regex: the calls span several
/// lines and carry a parameter map with its own braces and parens, and a
/// non-greedy regex stops at the first `)` inside the map.
List<String> _filterExprArguments(String source) {
  final out = <String>[];
  for (final match in 'filterExpr('.allMatches(source)) {
    var depth = 1;
    var index = match.end;
    while (index < source.length && depth > 0) {
      final char = source[index];
      if (char == '(') depth++;
      if (char == ')') depth--;
      index++;
    }
    out.add(source.substring(match.end, index - 1).trim());
  }
  return out;
}
