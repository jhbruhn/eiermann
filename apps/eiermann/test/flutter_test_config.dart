import 'dart:async';

import 'package:eiermann/config/zugvogel_bindings.dart';

/// Flutter runs this around every test in the package, which is the only hook
/// that reaches all of them.
///
/// It binds zugvogel once: the shared providers need a `PbClientConfig` and the
/// shared widgets need a `ZugvogelStrings`, and a widget test that builds its
/// own `ProviderScope` and `MaterialApp` — which most do — has no reason to
/// know either exists. A test that genuinely wants a different config still
/// overrides `pbClientConfigProvider` in its own scope and wins.
///
/// The production counterpart is `bindZugvogel()` in `bootstrap()`.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  bindZugvogel();
  await testMain();
}
