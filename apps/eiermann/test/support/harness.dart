import 'package:eiermann/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

/// Pumps `child` with everything a screen in this app needs: the real
/// localizations (so assertions can read the German the user sees), Material,
/// and a ProviderScope the test can override into.
extension PumpApp on WidgetTester {
  Future<void> pumpApp(
    Widget child, {
    List<Override> overrides = const [],
  }) async {
    await pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          // German explicitly: this app's copy is written in German first, and
          // a
          // test that ran under the device locale would assert on whichever
          // language the machine happened to prefer.
          locale: const Locale('de'),
          home: child,
        ),
      ),
    );
    await pump();
  }
}

/// The German strings, for asserting on what the user actually reads.
Future<AppLocalizations> germanStrings() =>
    AppLocalizations.delegate.load(const Locale('de'));

/// Gives the test a surface `size` logical pixels big, and undoes it
/// afterwards.
///
/// **Why every test that reaches below the fold needs this.** The default test
/// surface is 800x600, and a `ListView` does not build what is below the fold.
/// So inserting anything above a button makes the button *cease to exist* for
/// `find.byType` — and the test does not report a layout problem, it reports
/// "the control is missing", which reads as a bug in the screen. Scrolling by
/// hand instead is worse: it passes for the wrong reason the day the list is
/// short enough not to scroll.
///
/// **Why it is a helper and not three lines per test.** The three lines are
/// `physicalSize`, `devicePixelRatio` and the teardown, and the teardown is the
/// one that gets written wrong. `resetPhysicalSize` restores the size and
/// leaves the pixel ratio at 1 — so the NEXT test in the same file runs at a
/// ratio it never asked for, and the surface it thinks is 800x600 logical is
/// 800x600 physical. Fifteen call sites had written it both ways.
extension SurfaceSize on WidgetTester {
  void useSurface(Size size) {
    view.physicalSize = size;
    // Set together, always: physicalSize is in PHYSICAL pixels, so without a
    // ratio of 1 the logical surface is the size divided by whatever the host
    // reported, and the number in the test means nothing.
    view.devicePixelRatio = 1;
    // `reset`, not `resetPhysicalSize` — see the doc above.
    addTearDown(view.reset);
  }
}

/// Material's German localizations, for asserting on a date the way the widget
/// renders it.
///
/// The same delegate the app loads, so an assertion built with this cannot pass
/// over a date rendered in the wrong time zone: `formatLocalDate` converts, and
/// PocketBase stores UTC.
Future<MaterialLocalizations> germanMaterialStrings() =>
    GlobalMaterialLocalizations.delegate.load(const Locale('de'));
