import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'sweep_sources.dart';

void main() {
  final root = repoRoot.path;
  final workflow = File(
    '$root/.github/workflows/ci.yml',
  ).readAsLinesSync();

  group('the analyze gate', () {
    test('analyze runs from the repo root', () {
      // A run inside apps/eiermann analyses the APP and stops there. That is
      // how nine findings in a federfall package shipped: every one of them was
      // in a package, the app was clean, and the job was green.
      //
      // The property is the absence of a `working-directory` on that step,
      // which is why it is checked against the step's own block rather than
      // against the file: a `working-directory` two steps below is fine and
      // must not fail this.
      final at = workflow.indexWhere(
        (line) => line.contains('flutter analyze'),
      );
      expect(at, greaterThan(0), reason: 'CI does not analyse at all');
      final step = workflow.sublist(
        _stepStart(workflow, at),
        _stepEnd(workflow, at),
      );
      expect(
        step.where((line) => line.contains('working-directory')),
        isEmpty,
        reason:
            'analyze must run from the root: ${step.join(' | ')}. A '
            'subdirectory run covers that member only.',
      );
    });

    test('no step analyses a package on its own', () {
      // `dart analyze` inside a pure-Dart package crashes the analysis server
      // here, so it cannot be the packages' lint gate even if somebody wanted
      // it to be — which makes the root run the ONLY gate they have, and makes
      // a per-package step a false sense that they are covered.
      //
      // Comment lines are blanked: the workflow's own explanation of why
      // analyze has no working-directory names the thing being banned, and a
      // guard that fired on its rationale would delete the rationale.
      final offenders = workflow
          .where((line) => !line.trimLeft().startsWith('#'))
          .where(
            (line) =>
                line.contains('dart analyze') ||
                // A path argument narrows the run to that path, which is the
                // subdirectory mistake with the directory spelled inline.
                RegExp(r'flutter analyze\s+\S').hasMatch(line),
          )
          .toList();
      expect(offenders, isEmpty, reason: '$offenders');
    });

    test('every member on disk is in the workspace and in the sweeps', () {
      // The root run and every guard in this directory read the workspace, so a
      // member that is on disk and not in the list is analysed against no
      // resolution and swept by nothing — invisible in exactly the way the nine
      // findings were.
      final onDisk = [
        for (final parent in ['apps', 'packages'])
          for (final entry in Directory('$root/$parent').listSync())
            if (entry is Directory &&
                File('${entry.path}/pubspec.yaml').existsSync())
              '$parent/${entry.path.split('/').last}',
      ]..sort();

      final declared =
          File('$root/pubspec.yaml')
              .readAsLinesSync()
              .map(
                (line) => RegExp(r'^\s*-\s*(\S+)').firstMatch(line)?.group(1),
              )
              .whereType<String>()
              .toList()
            ..sort();

      expect(declared, onDisk, reason: "root pubspec's `workspace:` is stale");
      expect(
        [...sweptMembers]..sort(),
        onDisk,
        reason:
            'sweptMembers in sweep_sources.dart is stale — the guards in '
            'this directory would read past a whole member',
      );
    });
  });
}

/// The index of the `- name:` line that opens the step containing [at].
int _stepStart(List<String> lines, int at) {
  for (var i = at; i >= 0; i--) {
    if (lines[i].trimLeft().startsWith('- name:')) return i;
  }
  return at;
}

/// The index just past the last line of the step containing [at].
int _stepEnd(List<String> lines, int at) {
  for (var i = at + 1; i < lines.length; i++) {
    if (lines[i].trimLeft().startsWith('- name:') ||
        RegExp(r'^\s{0,4}\w').hasMatch(lines[i])) {
      return i;
    }
  }
  return lines.length;
}
