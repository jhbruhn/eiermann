import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'sweep_sources.dart';

/// What a generator writes, and nothing else may.
const _generatedSuffixes = ['.g.dart', '.freezed.dart', '.config.dart'];

/// Options CI must not pass, and what they were.
///
/// A removed flag is worse than no flag: it warns on a line nobody reads, and
/// it reads as a safeguard that is doing something. The next person to hit a
/// conflicting-output error sees `--delete-conflicting-outputs` already in the
/// workflow and goes looking somewhere else.
const _removedFlags = ['--delete-conflicting-outputs'];

void main() {
  final root = repoRoot.path;

  group('generated code', () {
    test('nothing generated is tracked', () {
      // Generated files are built, not committed — a stale one produces errors
      // that name neither the generator nor the ARB, and the reader spends the
      // afternoon on a compile error in a file they never wrote. The rule only
      // holds if the tracked set is checked; a .gitignore entry does not
      // un-track a file that was added before it.
      final tracked = _git(['ls-files'], root)
          .split('\n')
          .where(
            (path) =>
                _generatedSuffixes.any(path.endsWith) ||
                path.contains('/l10n/gen/'),
          )
          .toList();
      expect(
        tracked,
        isEmpty,
        reason:
            'git rm --cached these. They are rebuilt by `flutter gen-l10n` and '
            '`dart run build_runner build`.',
      );
    });

    test('every generated file on disk is ignored', () {
      // The other direction, and the one a fresh checkout cannot show you: a
      // NEW generated suffix (a new generator, a renamed output) is untracked
      // and unignored, so it is invisible here and lands in somebody's next
      // `git add .`.
      final onDisk = <String>[];
      for (final member in sweptMembers) {
        final lib = Directory('$root/$member/lib');
        if (!lib.existsSync()) continue;
        onDisk.addAll(
          lib
              .listSync(recursive: true)
              .whereType<File>()
              .map((f) => f.path.substring(root.length + 1))
              .where(
                (path) =>
                    _generatedSuffixes.any(path.endsWith) ||
                    path.contains('/l10n/gen/'),
              ),
        );
      }
      // Codegen has run if the suite got this far — every model is freezed.
      expect(
        onDisk,
        isNotEmpty,
        reason:
            'no generated file found at all: run `flutter gen-l10n` and '
            '`dart run build_runner build`, or this check passed over nothing',
      );
      final unignored = onDisk
          .where(
            (path) =>
                _git(
                  ['check-ignore', '--quiet', path],
                  root,
                  allowFail: true,
                ) ==
                'MISS',
          )
          .toList();
      expect(unignored, isEmpty, reason: 'add these to .gitignore');
    });

    test('CI regenerates before it analyses', () {
      // Analyze against a tree with no generated code reports hundreds of
      // missing symbols and one real finding, and nobody reads to the end of
      // that. Order, not presence, is the property.
      final workflow = File(
        '$root/.github/workflows/ci.yml',
      ).readAsStringSync();
      final analyze = workflow.indexOf('flutter analyze');
      expect(analyze, greaterThan(0), reason: 'CI does not analyse at all');
      for (final step in ['flutter gen-l10n', 'build_runner build']) {
        final at = workflow.indexOf(step);
        expect(at, greaterThan(0), reason: 'CI never runs `$step`');
        expect(
          at,
          lessThan(analyze),
          reason: '`$step` runs AFTER analyze, so analyze sees a stale tree',
        );
      }
      // One build_runner step per member that has a generator: build_runner
      // generates only for the package it runs in, and a member added without
      // its own step is silently ungenerated.
      final generating = sweptMembers.where(
        (m) => File(
          '$root/$m/pubspec.yaml',
        ).readAsStringSync().contains('build_runner'),
      );
      for (final member in generating) {
        expect(
          workflow,
          contains('working-directory: $member'),
          reason: '$member has a generator but no build_runner step in CI',
        );
      }
    });

    test('CI passes no option build_runner has removed', () {
      // Comment lines are blanked first. The workflow EXPLAINS why the flag is
      // absent, right where somebody would otherwise re-add it, and a guard
      // that fired on its own rationale would force that explanation out.
      final workflow = File('$root/.github/workflows/ci.yml')
          .readAsLinesSync()
          .map((line) => line.trimLeft().startsWith('#') ? '' : line)
          .join('\n');
      for (final flag in _removedFlags) {
        expect(
          workflow,
          isNot(contains(flag)),
          reason:
              '$flag was removed from build_runner — it now warns and does '
              'nothing, while reading as a safeguard that works',
        );
      }
    });
  });
}

/// Runs git in [root]. Returns stdout, or `'MISS'` when [allowFail] and the
/// command exited non-zero (`check-ignore --quiet` answers 1 for "not
/// ignored").
String _git(List<String> arguments, String root, {bool allowFail = false}) {
  final result = Process.runSync('git', arguments, workingDirectory: root);
  if (result.exitCode != 0) {
    if (allowFail) return 'MISS';
    fail('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
  return (result.stdout as String).trim();
}
