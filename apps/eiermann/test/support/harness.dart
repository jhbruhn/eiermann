import 'package:eiermann/l10n/l10n.dart';
import 'package:flutter/material.dart';
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
