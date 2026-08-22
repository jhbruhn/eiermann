/// The roots a source sweep in this package has to read.
///
/// **Why a sweep reaches outside its own package.** `flutter test` runs with
/// the app as its working directory, so a sweep written the obvious way covers
/// `apps/eiermann/lib` and nothing else — and the two pure-Dart packages hold
/// every model, every enum and every repository, which is precisely where the
/// rules these guards enforce are broken. `dart test` inside those packages
/// cannot take over the job either: the guards need `flutter_test`, and adding
/// it to a pure-Dart package would drag the Flutter SDK into a package that
/// deliberately does not depend on it.
///
/// So the guards live here and read the whole workspace. The cost is that the
/// paths are relative to the repo root rather than to a package, which
/// [repoRoot] resolves.
library;

import 'dart:io';

import 'package:zugvogel_ui/testing.dart';

/// The workspace root, found by walking up from the current directory until a
/// `pubspec.yaml` declaring the workspace turns up.
///
/// Walked rather than hard-coded as `../..`: `flutter test` runs from the app
/// directory and an IDE sometimes runs a single test file from the repo root,
/// and a guard that only passes under one of them gets deleted rather than
/// fixed.
Directory get repoRoot {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 6; i++) {
    final pubspec = File('${dir.path}/pubspec.yaml');
    if (pubspec.existsSync() &&
        pubspec.readAsStringSync().contains('\nworkspace:')) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    'No workspace pubspec.yaml above ${Directory.current.path} — a source '
    'sweep cannot tell what it is supposed to read.',
  );
}

/// Every hand-written `lib/` in the workspace: the app and both packages.
///
/// A new workspace member added without a line here is covered by
/// `guards/analyze_gate_test.dart`, which reads the directories on disk and
/// fails when either this list or the root pubspec's `workspace:` falls
/// behind.
List<Directory> get sweptLibRoots => [
  for (final member in sweptMembers) Directory('${repoRoot.path}/$member/lib'),
];

/// The workspace members whose `lib/` the guards read, repo-relative.
const sweptMembers = <String>[
  'apps/eiermann',
  'packages/eiermann_models',
  'packages/eiermann_data',
];

/// Every hand-written Dart file under [sweptLibRoots], generated trees and
/// [allowlist] removed.
Iterable<File> sweptDartFiles({Iterable<String> allowlist = const []}) sync* {
  for (final root in sweptLibRoots) {
    yield* sweepableDartFiles(root, allowlist);
  }
}

/// [file]'s path with the repo root cut off, so a failure message names
/// something the reader can paste into an editor.
String relative(File file) {
  final root = '${repoRoot.path}/';
  return file.absolute.path.startsWith(root)
      ? file.absolute.path.substring(root.length)
      : file.path;
}
